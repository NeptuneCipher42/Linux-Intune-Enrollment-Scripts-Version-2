#!/usr/bin/env bash
#################################################################################################
# Red Hat Intune Enrollment Prep
# Author:  Nicholas Fisher
# Version: 3.0
#
# Prepares a RHEL (or AlmaLinux) machine, Azure VM or physical desktop, for Microsoft Intune
# enrollment.
#
# What it does:
#   1. Detects the RHEL major version, CPU architecture and whether it is running on an Azure VM
#   2. Runs pre-flight checks (root, internet, Microsoft repo for this release, disk, memory)
#   3. Updates the system and enables EPEL (+ CodeReady Builder), which Intune needs on
#      RHEL 10 (webkitgtk6.0) and xrdp needs on RHEL 9
#   4. Installs the GNOME desktop ("Server with GUI") if not already present
#   5. Azure VMs only (or with --remote): sets up RDP access, choosing the method automatically:
#        - RHEL 9 and older: xrdp from EPEL
#        - RHEL 10 and newer: GNOME Remote Desktop "remote login" (RHEL 10 removed the
#          Xorg server, so xrdp can no longer start GNOME)
#      and opens port 3389 in firewalld
#   6. Adds Microsoft's repositories with the correct signing key for the release
#        - RHEL 10+ Intune repo: microsoft-2025 key
#        - Older releases and the Edge repo: legacy microsoft key
#   7. Installs Microsoft Edge (stable) and the Intune Portal app
#   8. Verifies everything, prints a summary and reboots
#
# Safe to re-run: completed steps are detected and skipped.
#
# After reboot: sign into Microsoft Edge with your work account FIRST, then open the
# Microsoft Intune app to enroll. Skipping the Edge sign-in causes error 4ulu5.
#
# Usage:
#   sudo ./RedHat-Intune-Enrollment.sh [OPTIONS]
#
# Options:
#   --remote               Set up RDP even if this is not detected as an Azure VM
#   --no-remote            Skip RDP setup even on an Azure VM
#   --rdp-backend <name>   Force the RDP method: xrdp or grd (GNOME Remote Desktop)
#   --skip-desktop         Do not install a desktop environment
#   --no-reboot            Do not reboot at the end
#   --force                Continue on releases not on Microsoft's supported list
#   --dry-run              Show what would be done without changing anything
#   -h, --help             Show this help
#
# Environment variables (GNOME Remote Desktop only, for unattended runs):
#   RDP_USER, RDP_PASSWORD  RDP gateway credentials. If unset, you are prompted.
#
# Log file: /var/log/intune-enrollment-prep.log
#
# Exit codes:
#   0   Success
#   1   Not run as root / bad arguments
#   2   Unsupported OS, release or architecture
#   3   Cannot reach required Microsoft or Fedora (EPEL) servers
#   4   Pre-flight check failed (disk space)
#   5   System update, EPEL or prerequisite install failed
#   6   Desktop install failed
#   7   Remote desktop setup failed
#   8   Microsoft key or repository setup failed
#   9   Microsoft Edge install failed
#   10  Intune Portal install failed
#   11  Final verification failed
#
# Supported (per Microsoft, Oct 2026): RHEL 9 and RHEL 10 on x86_64 with a GNOME desktop.
# Microsoft's own installer also accepts AlmaLinux. The RHEL system must be registered
# (Red Hat subscription, or Azure RHUI on pay-as-you-go images) so dnf can install packages.
#
# Azure VM differences handled here:
#   - Azure RHEL images are minimal servers: no desktop, display manager or GNOME keyring
#   - Pay-as-you-go images use Azure RHUI repos (CodeReady Builder has an RHUI-specific name)
#   - Admin users are often SSH-key only with no password (needed for desktop/RDP login)
#   - cloud-init may still be running on first boot (script waits for it)
#   - No local screen: RDP is needed (open 3389 in the NSG, or use Azure Bastion Standard)
#################################################################################################

set -uo pipefail

SCRIPT_VERSION="3.0"
LOG_FILE="/var/log/intune-enrollment-prep.log"
MS_BASE="https://packages.microsoft.com"
KEY_LEGACY_URL="$MS_BASE/keys/microsoft.asc"
KEY_2025_URL="$MS_BASE/keys/microsoft-2025.asc"
DOCUMENTED_MAJORS=("9" "10")
MIN_DISK_GB=10
MIN_RAM_MB=3500
AZURE_ASSET_TAG="7783-7084-3265-9085-8269-3286-77"

REMOTE_MODE="auto"        # auto | yes | no
RDP_BACKEND="auto"        # auto | xrdp | grd
SKIP_DESKTOP=false
DO_REBOOT=true
FORCE=false
DRY_RUN=false

DNF=(dnf -y)

# ---------------------------------------------------------------------------- helpers
log()  { echo "[$(date '+%F %T')] [INFO]  $*"; }
warn() { echo "[$(date '+%F %T')] [WARN]  $*"; }
fail() { echo "[$(date '+%F %T')] [ERROR] $2 (exit code $1)"; exit "$1"; }
step() { echo; echo "==== $* ===="; }
is_installed() { rpm -q "$1" >/dev/null 2>&1; }
url_ok() { curl -fsS --max-time 20 -o /dev/null "$1"; }

# Runs a command, or just prints it in --dry-run mode
run() {
  if $DRY_RUN; then echo "[DRY-RUN] $*"; return 0; fi
  "$@"
}

usage() { sed -n '/^# Usage:/,/^# Log file:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ---------------------------------------------------------------------------- arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)        REMOTE_MODE="yes" ;;
    --no-remote)     REMOTE_MODE="no" ;;
    --rdp-backend)   [[ $# -ge 2 ]] || { echo "--rdp-backend needs xrdp or grd"; exit 1; }
                     RDP_BACKEND="$2"; shift
                     [[ "$RDP_BACKEND" =~ ^(xrdp|grd)$ ]] || { echo "--rdp-backend must be xrdp or grd"; exit 1; } ;;
    --skip-desktop)  SKIP_DESKTOP=true ;;
    --no-reboot)     DO_REBOOT=false ;;
    --force)         FORCE=true ;;
    --dry-run)       DRY_RUN=true; DO_REBOOT=false ;;
    -h|--help)       usage ;;
    *)               echo "Unknown option: $1 (see --help)"; exit 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------- 1. root + logging
[[ $EUID -eq 0 ]] || { echo "Run this script with sudo: sudo $0 $*"; exit 1; }
exec > >(tee -a "$LOG_FILE") 2>&1
step "Red Hat Intune Enrollment Prep v$SCRIPT_VERSION"
$DRY_RUN && warn "DRY-RUN mode: no changes will be made."

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ "$TARGET_USER" == "root" ]] && warn "Run with sudo from your normal account so desktop settings go to that user, not root."

# ---------------------------------------------------------------------------- 2. detection
step "Detecting system"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  rhel|almalinux) ;;
  *) fail 2 "This script is for RHEL or AlmaLinux. Detected: ${PRETTY_NAME:-unknown}. Use the Ubuntu script for Ubuntu." ;;
esac
MAJOR="${VERSION_ID%%.*}"

ARCH="$(uname -m)"
[[ "$ARCH" == "x86_64" ]] || fail 2 "Intune for Linux requires x86_64. Detected: $ARCH"

IS_DOCUMENTED=false
for r in "${DOCUMENTED_MAJORS[@]}"; do [[ "$MAJOR" == "$r" ]] && IS_DOCUMENTED=true; done

IS_AZURE=false
if [[ "$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)" == "$AZURE_ASSET_TAG" ]]; then
  IS_AZURE=true
fi

log "OS:           $PRETTY_NAME"
log "Major:        $MAJOR"
log "Architecture: $ARCH"
log "Azure VM:     $IS_AZURE"
log "Desktop user: $TARGET_USER"

if ! $IS_DOCUMENTED; then
  if [[ "$MAJOR" -lt 9 ]]; then
    $FORCE || fail 2 "RHEL $MAJOR is no longer on Microsoft's Intune supported list (9, 10). Upgrade, or use --force."
    warn "RHEL $MAJOR is no longer officially supported by Intune. Continuing because of --force."
  else
    warn "RHEL $MAJOR is newer than Microsoft's documented list (${DOCUMENTED_MAJORS[*]}). Continuing; the repo check below decides if packages exist."
  fi
fi

# Decide whether to set up RDP
case "$REMOTE_MODE" in
  yes)  SETUP_REMOTE=true ;;
  no)   SETUP_REMOTE=false ;;
  auto) SETUP_REMOTE=$IS_AZURE ;;
esac
$SKIP_DESKTOP && SETUP_REMOTE=false

# Pick the RDP method: RHEL 10 removed the Xorg server, so xrdp cannot run GNOME there
if [[ "$RDP_BACKEND" == "auto" ]]; then
  if [[ "$MAJOR" -ge 10 ]]; then RDP_BACKEND="grd"; else RDP_BACKEND="xrdp"; fi
fi
if $SETUP_REMOTE; then log "Remote desktop: $RDP_BACKEND"; else log "Remote desktop: not configured"; fi

# Microsoft signing keys: RHEL 10+ Intune repo uses microsoft-2025; Edge always uses legacy
if [[ "$MAJOR" -ge 10 ]]; then INTUNE_KEY_URL="$KEY_2025_URL"; else INTUNE_KEY_URL="$KEY_LEGACY_URL"; fi

# ---------------------------------------------------------------------------- 3. pre-flight
step "Pre-flight checks"
command -v curl >/dev/null || run "${DNF[@]}" install curl || fail 5 "Could not install curl."

url_ok "$KEY_LEGACY_URL" || fail 3 "Cannot reach $MS_BASE. Check outbound internet, NSG rules or proxy."
INTUNE_REPO_URL="$MS_BASE/rhel/$MAJOR/prod"
url_ok "$INTUNE_REPO_URL/repodata/repomd.xml" \
  || fail 2 "Microsoft has not published an Intune repo for RHEL $MAJOR yet. Check https://learn.microsoft.com/intune for supported versions."
log "Microsoft Intune repo found for RHEL $MAJOR."

if [[ "$ID" == "rhel" ]] && ! $DRY_RUN; then
  dnf -q repolist --enabled 2>/dev/null | grep -qi "baseos" \
    || fail 5 "No RHEL BaseOS repo is enabled. Register the system (subscription-manager register) or check Azure RHUI."
fi

FREE_GB=$(( $(df --output=avail -k / | tail -1) / 1024 / 1024 ))
[[ $FREE_GB -ge $MIN_DISK_GB ]] || fail 4 "Only ${FREE_GB} GB free on /. Need at least ${MIN_DISK_GB} GB. (Azure RHEL images often have a small root LV; extend it first.)"
log "Disk space: ${FREE_GB} GB free on /."

RAM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
if [[ $RAM_MB -lt $MIN_RAM_MB ]]; then
  warn "Only ${RAM_MB} MB RAM. GNOME over RDP needs 4 GB+ to be usable."
else
  log "Memory: ${RAM_MB} MB."
fi

if command -v cloud-init >/dev/null && ! $DRY_RUN; then
  log "Waiting for cloud-init to finish (if running)..."
  cloud-init status --wait >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------- 4. update + EPEL
step "Updating system"
run "${DNF[@]}" upgrade --refresh || fail 5 "System update failed."
run "${DNF[@]}" install curl ca-certificates openssl dnf-plugins-core || fail 5 "Failed to install prerequisites."

step "EPEL and CodeReady Builder"
# EPEL packages often depend on CodeReady Builder. Its repo ID differs between
# subscription-managed RHEL, Azure RHUI images and AlmaLinux ("crb"), so look it up.
CRB_REPO="$(dnf repolist --all -q 2>/dev/null | awk '{print $1}' \
  | grep -Ei '^crb$|codeready-builder' | grep -viE 'debug|source' | head -1)"
if [[ -n "$CRB_REPO" ]]; then
  if dnf repolist --enabled -q 2>/dev/null | awk '{print $1}' | grep -qx "$CRB_REPO"; then
    log "CodeReady Builder ($CRB_REPO) already enabled."
  else
    run dnf config-manager --set-enabled "$CRB_REPO" || warn "Could not enable $CRB_REPO. Some EPEL packages may fail."
    log "Enabled CodeReady Builder: $CRB_REPO"
  fi
else
  warn "No CodeReady Builder repo found. Continuing; EPEL installs may fail if they need it."
fi

if is_installed epel-release; then
  log "EPEL already installed. Skipping."
else
  EPEL_URL="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${MAJOR}.noarch.rpm"
  url_ok "$EPEL_URL" || fail 3 "Cannot reach EPEL at $EPEL_URL."
  run "${DNF[@]}" install "$EPEL_URL" || fail 5 "EPEL install failed."
fi

# ---------------------------------------------------------------------------- 5. desktop
step "Desktop environment"
if $SKIP_DESKTOP; then
  log "--skip-desktop set. Skipping."
elif is_installed gnome-shell && is_installed gdm; then
  log "GNOME desktop already installed. Skipping."
else
  log "Installing GNOME desktop (Server with GUI). This can take 10+ minutes..."
  run "${DNF[@]}" groupinstall "Server with GUI" || fail 6 "GNOME desktop install failed."
fi
if ! $SKIP_DESKTOP; then
  run systemctl set-default graphical.target || fail 6 "Could not set graphical boot target."
  run systemctl enable gdm >/dev/null 2>&1 || warn "Could not enable gdm."
fi

# ---------------------------------------------------------------------------- 6. remote desktop
open_firewall() {
  if systemctl is-active --quiet firewalld; then
    if firewall-cmd --query-port=3389/tcp >/dev/null 2>&1; then
      log "firewalld already allows 3389/tcp."
    else
      run firewall-cmd --permanent --add-port=3389/tcp || return 1
      run firewall-cmd --reload || return 1
      log "firewalld: opened 3389/tcp."
    fi
  else
    log "firewalld not running. Nothing to open locally (remember the Azure NSG / Bastion)."
  fi
}

add_keyring_pam() {
  # Unlocks the GNOME keyring at RDP login so the Intune/Entra sign-in can store credentials.
  local pam="/etc/pam.d/xrdp-sesman"
  [[ -f "$pam" ]] || return 0
  grep -q "pam_gnome_keyring.so" "$pam" && { log "GNOME keyring already in xrdp PAM. Skipping."; return 0; }
  run cp -n "$pam" "$pam.bak" || return 1
  if ! $DRY_RUN; then
    echo "auth       optional     pam_gnome_keyring.so" >> "$pam"
    echo "session    optional     pam_gnome_keyring.so auto_start" >> "$pam"
  fi
  log "Added GNOME keyring unlock to $pam (backup: $pam.bak)."
}

setup_xrdp() {
  if is_installed xrdp && is_installed xorgxrdp; then
    log "xrdp already installed. Skipping install."
  else
    run "${DNF[@]}" install xrdp xorgxrdp || return 1
  fi
  add_keyring_pam || return 1

  # xrdp starts ~/.Xclients on RHEL; point it at GNOME for the user and future users
  local dir
  for dir in "$TARGET_HOME" /etc/skel; do
    if [[ "$(cat "$dir/.Xclients" 2>/dev/null)" != "gnome-session" ]]; then
      $DRY_RUN || { echo "gnome-session" > "$dir/.Xclients" && chmod 755 "$dir/.Xclients"; } || return 1
      log "Wrote $dir/.Xclients"
    fi
  done
  run chown "$TARGET_USER:" "$TARGET_HOME/.Xclients"

  # SELinux: EPEL's xrdp binaries need the bin_t context to launch sessions when enforcing
  if command -v getenforce >/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
    run chcon --type=bin_t /usr/sbin/xrdp /usr/sbin/xrdp-sesman || warn "Could not set SELinux context on xrdp."
    log "SELinux enforcing: set bin_t context on xrdp binaries."
  fi

  systemctl list-unit-files gnome-remote-desktop.service >/dev/null 2>&1 && \
    run systemctl disable --now gnome-remote-desktop.service >/dev/null 2>&1
  run systemctl enable xrdp || return 1
  run systemctl restart xrdp || return 1
}

setup_grd() {
  run "${DNF[@]}" install gnome-remote-desktop || return 1
  if is_installed xrdp; then
    warn "Removing xrdp: it cannot start GNOME on RHEL $MAJOR and would block port 3389."
    run systemctl disable --now xrdp >/dev/null 2>&1
    run "${DNF[@]}" remove xrdp xorgxrdp || return 1
  fi

  local grd_user="gnome-remote-desktop"
  local grd_home; grd_home="$(getent passwd "$grd_user" | cut -d: -f6)"
  if [[ -z "$grd_home" ]]; then
    $DRY_RUN || { warn "System user $grd_user not found (gnome-remote-desktop package problem)."; return 1; }
    grd_home="/var/lib/gnome-remote-desktop"
  fi
  local cert_dir="$grd_home/.local/share/gnome-remote-desktop"

  if [[ -s "$cert_dir/tls.crt" && -s "$cert_dir/tls.key" ]]; then
    log "GNOME Remote Desktop TLS certificate already exists. Skipping."
  else
    run runuser -u "$grd_user" -- mkdir -p "$cert_dir" || return 1
    run runuser -u "$grd_user" -- openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
      -subj "/CN=$(hostname)" -keyout "$cert_dir/tls.key" -out "$cert_dir/tls.crt" || return 1
    log "Generated self-signed TLS certificate in $cert_dir."
  fi

  # TLS files cannot be changed while RDP is enabled
  run grdctl --system rdp disable >/dev/null 2>&1
  run grdctl --system rdp set-tls-key "$cert_dir/tls.key" || return 1
  run grdctl --system rdp set-tls-cert "$cert_dir/tls.crt" || return 1

  if [[ -n "${RDP_USER:-}" && -n "${RDP_PASSWORD:-}" ]]; then
    run grdctl --system rdp set-credentials "$RDP_USER" "$RDP_PASSWORD" || return 1
    log "RDP gateway credentials set for $RDP_USER (from environment)."
  elif [[ -t 0 ]] && ! $DRY_RUN; then
    echo
    echo "Set the RDP gateway login. This is the first prompt your RDP client shows;"
    echo "after it, the normal RHEL login screen asks for your account password."
    grdctl --system rdp set-credentials </dev/tty || return 1
  else
    $DRY_RUN || { warn "No terminal and RDP_USER/RDP_PASSWORD not set. Run: sudo grdctl --system rdp set-credentials"; return 1; }
  fi

  run grdctl --system rdp enable || return 1
  run systemctl enable --now gnome-remote-desktop.service || return 1
}

step "Remote desktop"
if $SETUP_REMOTE; then
  if [[ "$RDP_BACKEND" == "xrdp" ]]; then
    [[ "$MAJOR" -ge 10 ]] && warn "xrdp forced on RHEL $MAJOR: there is no Xorg server here, so expect it to fail."
    setup_xrdp || fail 7 "xrdp setup failed."
  else
    setup_grd || fail 7 "GNOME Remote Desktop setup failed."
  fi
  open_firewall || fail 7 "Could not open port 3389 in firewalld."
else
  log "Skipping remote desktop setup (physical machine or --no-remote)."
fi

# ---------------------------------------------------------------------------- 7. Microsoft repos
step "Microsoft repositories"
# Remove incomplete repo files created by 'dnf config-manager --add-repo' in older installers
for f in /etc/yum.repos.d/packages.microsoft.com_*.repo; do
  [[ -f "$f" ]] && { run rm -f "$f"; log "Removed legacy repo file $f"; }
done

run rpm --import "$KEY_LEGACY_URL" || fail 8 "Could not import Microsoft key."
if [[ "$INTUNE_KEY_URL" == "$KEY_2025_URL" ]]; then
  run rpm --import "$KEY_2025_URL" || fail 8 "Could not import microsoft-2025 key."
fi
log "Microsoft signing keys imported."

# Only add our repo files if the admin hasn't already enrolled these repos elsewhere
repo_enrolled_elsewhere() { # $1 = URL fragment, $2 = our file name
  local f
  for f in /etc/yum.repos.d/*.repo; do
    [[ -f "$f" && "$(basename "$f")" != "$2" ]] || continue
    grep -iE '^[[:space:]]*baseurl[[:space:]]*=' "$f" | grep -qF "$1" && \
      ! grep -qiE '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*0' "$f" && return 0
  done
  return 1
}

write_repo() { # $1 = file, $2 = id, $3 = name, $4 = baseurl, $5 = key URL
  if $DRY_RUN; then echo "[DRY-RUN] write /etc/yum.repos.d/$1 ($4)"; return 0; fi
  cat > "/etc/yum.repos.d/$1" <<EOF
[$2]
name=$3
baseurl=$4
enabled=1
gpgcheck=1
gpgkey=$5
EOF
}

if repo_enrolled_elsewhere "packages.microsoft.com/rhel/$MAJOR/prod" "microsoft-prod.repo"; then
  log "Microsoft RHEL repo already configured elsewhere. Skipping."
  run rm -f /etc/yum.repos.d/microsoft-prod.repo
else
  write_repo microsoft-prod.repo microsoft-prod "Microsoft prod - RHEL $MAJOR" "$INTUNE_REPO_URL" "$INTUNE_KEY_URL" \
    || fail 8 "Could not write Intune repo file."
  log "Intune repo: $INTUNE_REPO_URL, key $(basename "$INTUNE_KEY_URL")"
fi

if repo_enrolled_elsewhere "packages.microsoft.com/yumrepos/edge" "microsoft-edge.repo"; then
  log "Edge repo already configured elsewhere. Skipping."
else
  write_repo microsoft-edge.repo microsoft-edge "Microsoft Edge" "$MS_BASE/yumrepos/edge" "$KEY_LEGACY_URL" \
    || fail 8 "Could not write Edge repo file."
  log "Edge repo configured (legacy key)."
fi

run dnf -q makecache || fail 8 "dnf could not read the Microsoft repos (check for GPG errors above)."

# ---------------------------------------------------------------------------- 8. Edge + Intune
step "Microsoft Edge and Intune Portal"
if is_installed microsoft-edge-stable; then
  log "Microsoft Edge already installed. Checking for updates..."
  run "${DNF[@]}" upgrade microsoft-edge-stable || warn "Edge update check failed."
else
  run "${DNF[@]}" install microsoft-edge-stable || fail 9 "Microsoft Edge install failed."
fi

if is_installed intune-portal; then
  log "Intune Portal already installed. Checking for updates..."
  run "${DNF[@]}" upgrade intune-portal || warn "Intune Portal update check failed."
else
  run "${DNF[@]}" install intune-portal || fail 10 "Intune Portal install failed (on RHEL 10 this usually means EPEL or CRB is missing)."
fi

# ---------------------------------------------------------------------------- 9. verify + summary
step "Verification"
if ! $DRY_RUN; then
  is_installed microsoft-edge-stable || fail 11 "Microsoft Edge not detected after install."
  is_installed intune-portal        || fail 11 "Intune Portal not detected after install."
  if $SETUP_REMOTE; then
    if [[ "$RDP_BACKEND" == "xrdp" ]]; then
      systemctl is-active --quiet xrdp || fail 11 "xrdp is not running."
    else
      systemctl is-active --quiet gnome-remote-desktop || fail 11 "gnome-remote-desktop is not running."
    fi
  fi
fi

pkg_ver() { rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null || echo "n/a"; }
step "Summary"
log "OS:              $PRETTY_NAME"
log "Azure VM:        $IS_AZURE"
log "Microsoft Edge:  $(pkg_ver microsoft-edge-stable)"
log "Intune Portal:   $(pkg_ver intune-portal)"
log "Intune repo key: $(basename "$INTUNE_KEY_URL")"
if $SETUP_REMOTE; then
  log "Remote desktop:  $RDP_BACKEND on port 3389"
  $IS_AZURE && log "Azure:           allow 3389 in the NSG, or connect through Azure Bastion (Standard SKU) over RDP."
else
  log "Remote desktop:  not configured"
fi
log "Log file:        $LOG_FILE"
echo
log "NEXT STEPS after reboot:"
log "  1. Sign in to the desktop as $TARGET_USER$($SETUP_REMOTE && echo ' over RDP')."
log "  2. Open Microsoft Edge and sign in with your work account FIRST."
log "  3. Open the Microsoft Intune app and follow the enrollment prompts."
log "  4. Confirm the device appears in the Intune admin center (https://intune.microsoft.com)."
if [[ "$TARGET_USER" != "root" ]] && ! passwd -S "$TARGET_USER" 2>/dev/null | awk '{exit !($2=="PS" || $2=="P")}'; then
  warn "$TARGET_USER has no password set (common on Azure SSH-key VMs). Set one for desktop login: sudo passwd $TARGET_USER"
fi

if $DO_REBOOT; then
  log "Rebooting in 15 seconds (Ctrl+C to cancel)..."
  sleep 15
  reboot
else
  log "Reboot skipped. Reboot before enrolling."
fi
exit 0
