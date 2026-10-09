#!/usr/bin/env bash
#################################################################################################
# Ubuntu Intune Enrollment Prep
# Author:  Nicholas Fisher
# Version: 3.0
#
# Prepares an Ubuntu LTS machine (Azure VM or physical desktop) for Microsoft Intune enrollment.
#
# What it does:
#   1. Detects the Ubuntu release, CPU architecture and whether it is running on an Azure VM
#   2. Runs pre-flight checks (root, internet, disk space, memory, apt locks)
#   3. Updates the system
#   4. Installs a minimal GNOME desktop if one is not already present
#   5. Azure VMs only (or with --remote): sets up RDP access, choosing the method automatically:
#        - Ubuntu 24.04 and older: xrdp (GNOME still has an X11 session)
#        - Ubuntu 25.10 and newer: GNOME Remote Desktop "remote login" (GNOME 49+ removed
#          X11 sessions, so xrdp can no longer start GNOME)
#   6. Adds Microsoft's repositories with the correct signing key for the release
#        - Ubuntu 26.04+ Intune repo: microsoft-2025 key
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
#   sudo ./Ubuntu-Intune-Enrollment.sh [OPTIONS]
#
# Options:
#   --remote               Set up RDP even if this is not detected as an Azure VM
#   --no-remote            Skip RDP setup even on an Azure VM
#   --rdp-backend <name>   Force the RDP method: xrdp or grd (GNOME Remote Desktop)
#   --skip-desktop         Do not install a desktop environment
#   --no-reboot            Do not reboot at the end
#   --force                Continue on Ubuntu releases not on Microsoft's supported list
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
#   3   Cannot reach required Microsoft or Ubuntu servers
#   4   Pre-flight check failed (disk space, apt lock)
#   5   System update or prerequisite install failed
#   6   Desktop install failed
#   7   Remote desktop setup failed
#   8   Microsoft key or repository setup failed
#   9   Microsoft Edge install failed
#   10  Intune Portal install failed
#   11  Final verification failed
#
# Supported (per Microsoft, Oct 2026): Ubuntu Desktop 24.04 LTS and 26.04 LTS on x86_64
# physical machines, Azure VMs or Hyper-V VMs, with a GNOME desktop. Ubuntu Server is not
# supported as-is, which is why this script adds a desktop to Azure's server images.
#
# Azure VM differences handled here:
#   - Azure images are Ubuntu Server: no desktop, display manager or GNOME keyring
#   - Admin users are often SSH-key only with no password (needed for desktop/RDP login)
#   - cloud-init may still be running apt on first boot (script waits for it)
#   - No local screen: RDP is needed (open 3389 in the NSG, or use Azure Bastion Standard)
#   - The GNOME keyring must unlock at RDP login for the Intune/Entra sign-in to work
#################################################################################################
 
set -uo pipefail
 
SCRIPT_VERSION="3.0"
LOG_FILE="/var/log/intune-enrollment-prep.log"
MS_BASE="https://packages.microsoft.com"
KEY_LEGACY="/usr/share/keyrings/microsoft.gpg"
KEY_2025="/usr/share/keyrings/microsoft-2025.gpg"
DOCUMENTED_RELEASES=("24.04" "26.04")
MIN_DISK_GB=10
MIN_RAM_MB=3500
AZURE_ASSET_TAG="7783-7084-3265-9085-8269-3286-77"
 
REMOTE_MODE="auto"        # auto | yes | no
RDP_BACKEND="auto"        # auto | xrdp | grd
SKIP_DESKTOP=false
DO_REBOOT=true
FORCE=false
DRY_RUN=false
 
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o DPkg::Lock::Timeout=600)
 
# ---------------------------------------------------------------------------- helpers
log()  { echo "[$(date '+%F %T')] [INFO]  $*"; }
warn() { echo "[$(date '+%F %T')] [WARN]  $*"; }
fail() { echo "[$(date '+%F %T')] [ERROR] $2 (exit code $1)"; exit "$1"; }
step() { echo; echo "==== $* ===="; }
is_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
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
step "Ubuntu Intune Enrollment Prep v$SCRIPT_VERSION"
$DRY_RUN && warn "DRY-RUN mode: no changes will be made."
 
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ "$TARGET_USER" == "root" ]] && warn "Run with sudo from your normal account so desktop settings go to that user, not root."
 
# ---------------------------------------------------------------------------- 2. detection
step "Detecting system"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail 2 "This script is for Ubuntu. Detected: ${PRETTY_NAME:-unknown}. Use the RHEL script for Red Hat."
 
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || fail 2 "Intune for Linux requires x86_64 (amd64). Detected: $ARCH"
 
IS_LTS=false; [[ "${VERSION:-}" == *LTS* ]] && IS_LTS=true
IS_DOCUMENTED=false
for r in "${DOCUMENTED_RELEASES[@]}"; do [[ "$VERSION_ID" == "$r" ]] && IS_DOCUMENTED=true; done
 
IS_AZURE=false
if [[ "$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)" == "$AZURE_ASSET_TAG" ]]; then
  IS_AZURE=true
fi
 
log "OS:           $PRETTY_NAME ($VERSION_CODENAME)"
log "Architecture: $ARCH"
log "Azure VM:     $IS_AZURE"
log "Desktop user: $TARGET_USER"
 
if ! $IS_LTS; then
  $FORCE || fail 2 "$PRETTY_NAME is not an LTS release. Intune only supports Ubuntu LTS. Use --force to continue anyway."
  warn "Non-LTS release, continuing because of --force."
fi
if ! $IS_DOCUMENTED; then
  if dpkg --compare-versions "$VERSION_ID" lt "24.04"; then
    $FORCE || fail 2 "Ubuntu $VERSION_ID is no longer on Microsoft's Intune supported list (24.04, 26.04). Upgrade, or use --force."
    warn "Ubuntu $VERSION_ID is no longer officially supported by Intune. Continuing because of --force."
  else
    warn "Ubuntu $VERSION_ID is newer than Microsoft's documented list (${DOCUMENTED_RELEASES[*]}). Continuing; the repo check below decides if packages exist."
  fi
fi
 
# Decide whether to set up RDP
case "$REMOTE_MODE" in
  yes)  SETUP_REMOTE=true ;;
  no)   SETUP_REMOTE=false ;;
  auto) SETUP_REMOTE=$IS_AZURE ;;
esac
$SKIP_DESKTOP && SETUP_REMOTE=false
 
# Pick the RDP method: GNOME 49+ (Ubuntu 25.10+) has no X11 session, so xrdp cannot run GNOME
if [[ "$RDP_BACKEND" == "auto" ]]; then
  if dpkg --compare-versions "$VERSION_ID" ge "25.10"; then RDP_BACKEND="grd"; else RDP_BACKEND="xrdp"; fi
fi
if $SETUP_REMOTE; then log "Remote desktop: $RDP_BACKEND"; else log "Remote desktop: not configured"; fi
 
# Microsoft signing keys: Ubuntu 26.04+ Intune repo uses microsoft-2025; Edge always uses legacy
if dpkg --compare-versions "$VERSION_ID" ge "26.04"; then INTUNE_KEY="$KEY_2025"; else INTUNE_KEY="$KEY_LEGACY"; fi
 
# ---------------------------------------------------------------------------- 3. pre-flight
step "Pre-flight checks"
command -v curl >/dev/null || run "${APT[@]}" install curl || fail 5 "Could not install curl."
 
url_ok "$MS_BASE/keys/microsoft.asc" || fail 3 "Cannot reach $MS_BASE. Check outbound internet, NSG rules or proxy."
INTUNE_REPO_URL="$MS_BASE/ubuntu/$VERSION_ID/prod"
url_ok "$INTUNE_REPO_URL/dists/$VERSION_CODENAME/Release" \
  || fail 2 "Microsoft has not published an Intune repo for Ubuntu $VERSION_ID ($VERSION_CODENAME) yet. Check https://learn.microsoft.com/intune for supported versions."
log "Microsoft Intune repo found for $VERSION_ID."
 
FREE_GB=$(( $(df --output=avail -k / | tail -1) / 1024 / 1024 ))
[[ $FREE_GB -ge $MIN_DISK_GB ]] || fail 4 "Only ${FREE_GB} GB free on /. Need at least ${MIN_DISK_GB} GB."
log "Disk space: ${FREE_GB} GB free."
 
RAM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
if [[ $RAM_MB -lt $MIN_RAM_MB ]]; then
  warn "Only ${RAM_MB} MB RAM. GNOME over RDP needs 4 GB+ to be usable (e.g. Azure Standard_B2s or larger)."
else
  log "Memory: ${RAM_MB} MB."
fi
 
# On first boot, cloud-init may still be running apt in the background
if command -v cloud-init >/dev/null && ! $DRY_RUN; then
  log "Waiting for cloud-init to finish (if running)..."
  cloud-init status --wait >/dev/null 2>&1 || true
fi
 
# ---------------------------------------------------------------------------- 4. update
step "Updating system"
run "${APT[@]}" update || fail 5 "apt update failed."
run "${APT[@]}" full-upgrade || fail 5 "System upgrade failed."
run "${APT[@]}" install curl gpg ca-certificates openssl || fail 5 "Failed to install prerequisites."
 
# ---------------------------------------------------------------------------- 5. desktop
step "Desktop environment"
if $SKIP_DESKTOP; then
  log "--skip-desktop set. Skipping."
elif is_installed ubuntu-desktop-minimal || is_installed ubuntu-desktop; then
  log "GNOME desktop already installed. Skipping."
else
  log "Installing minimal GNOME desktop (this can take 10+ minutes)..."
  run "${APT[@]}" install ubuntu-desktop-minimal || fail 6 "GNOME desktop install failed."
fi
if ! $SKIP_DESKTOP; then
  run systemctl set-default graphical.target || fail 6 "Could not set graphical boot target."
fi
 
# ---------------------------------------------------------------------------- 6. remote desktop
add_keyring_pam() {
  # Unlocks the GNOME keyring at RDP login so the Intune/Entra sign-in can store credentials.
  local pam="/etc/pam.d/xrdp-sesman"
  [[ -f "$pam" ]] || return 0
  grep -q "pam_gnome_keyring.so" "$pam" && { log "GNOME keyring already in xrdp PAM. Skipping."; return 0; }
  run cp -n "$pam" "$pam.bak" || return 1
  if ! $DRY_RUN; then
    echo "auth    optional        pam_gnome_keyring.so" >> "$pam"
    echo "session optional        pam_gnome_keyring.so auto_start" >> "$pam"
  fi
  log "Added GNOME keyring unlock to $pam (backup: $pam.bak)."
}
 
open_firewall() {
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    run ufw allow 3389/tcp || return 1
    log "UFW is active: allowed 3389/tcp."
  else
    log "UFW not active. Nothing to open locally (remember the Azure NSG / Bastion)."
  fi
}
 
setup_xrdp() {
  if is_installed xrdp && is_installed xorgxrdp; then
    log "xrdp already installed. Skipping install."
  else
    run "${APT[@]}" install xrdp xorgxrdp dbus-x11 || return 1
  fi
  id -nG xrdp 2>/dev/null | grep -qw ssl-cert || run adduser xrdp ssl-cert || return 1
  add_keyring_pam || return 1
 
  # Start Ubuntu GNOME (with the dock and taskbar) for RDP sessions.
  # Written for the desktop user and /etc/skel so future users get it too.
  local dir
  for dir in "$TARGET_HOME" /etc/skel; do
    if [[ "$(cat "$dir/.xsession" 2>/dev/null)" != "gnome-session" ]]; then
      $DRY_RUN || echo "gnome-session" > "$dir/.xsession" || return 1
      log "Wrote $dir/.xsession"
    fi
    if ! grep -q "GNOME_SHELL_SESSION_MODE=ubuntu" "$dir/.xsessionrc" 2>/dev/null; then
      $DRY_RUN || cat > "$dir/.xsessionrc" <<'EOF' || return 1
export XAUTHORITY=${HOME}/.Xauthority
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
EOF
      log "Wrote $dir/.xsessionrc"
    fi
    [[ "$dir" == "$TARGET_HOME" ]] && run chown "$TARGET_USER:" "$dir/.xsession" "$dir/.xsessionrc"
  done
  # GNOME Remote Desktop also listens on 3389 on newer releases; avoid a port clash
  systemctl list-unit-files gnome-remote-desktop.service >/dev/null 2>&1 && \
    run systemctl disable --now gnome-remote-desktop.service >/dev/null 2>&1 || true
  run systemctl enable xrdp || return 1
  run systemctl restart xrdp || return 1
}
 
setup_grd() {
  run "${APT[@]}" install gnome-remote-desktop || return 1
  # xrdp would hold port 3389 and cannot run GNOME on this release anyway
  if is_installed xrdp; then
    warn "Removing xrdp: it cannot start GNOME on Ubuntu $VERSION_ID and would block port 3389."
    run systemctl disable --now xrdp >/dev/null 2>&1 || true
    run "${APT[@]}" remove xrdp xorgxrdp || return 1
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
  run grdctl --system rdp disable >/dev/null 2>&1 || true
  run grdctl --system rdp set-tls-key "$cert_dir/tls.key" || return 1
  run grdctl --system rdp set-tls-cert "$cert_dir/tls.crt" || return 1
 
  if [[ -n "${RDP_USER:-}" && -n "${RDP_PASSWORD:-}" ]]; then
    run grdctl --system rdp set-credentials "$RDP_USER" "$RDP_PASSWORD" || return 1
    log "RDP gateway credentials set for $RDP_USER (from environment)."
  elif [[ -t 0 ]] && ! $DRY_RUN; then
    echo
    echo "Set the RDP gateway login. This is the first prompt your RDP client shows;"
    echo "after it, the normal Ubuntu login screen asks for your account password."
    grdctl --system rdp set-credentials </dev/tty || return 1
  else
    $DRY_RUN || { warn "No terminal and RDP_USER/RDP_PASSWORD not set. Run: sudo grdctl --system rdp set-credentials"; return 1; }
  fi
 
  run grdctl --system rdp enable || return 1
  run systemctl enable gdm3 >/dev/null 2>&1 || run systemctl enable gdm >/dev/null 2>&1 || true
  run systemctl enable --now gnome-remote-desktop.service || return 1
}
 
step "Remote desktop"
if $SETUP_REMOTE; then
  if [[ "$RDP_BACKEND" == "xrdp" ]]; then
    dpkg --compare-versions "$VERSION_ID" ge "25.10" && \
      warn "xrdp forced on Ubuntu $VERSION_ID: GNOME has no X11 session here, so expect a blank screen."
    setup_xrdp || fail 7 "xrdp setup failed."
  else
    setup_grd || fail 7 "GNOME Remote Desktop setup failed."
  fi
  open_firewall || fail 7 "Could not open port 3389 in UFW."
else
  log "Skipping remote desktop setup (physical machine or --no-remote)."
fi
 
# ---------------------------------------------------------------------------- 7. Microsoft repos
step "Microsoft repositories"
# Remove files from older versions of this script that can cause "conflicting Signed-By" errors
for f in /etc/apt/sources.list.d/microsoft-edge-dev.list \
         /etc/apt/sources.list.d/microsoft-ubuntu-*-prod.list \
         /etc/apt/trusted.gpg.d/microsoft.gpg; do
  [[ -e "$f" ]] && { run rm -f "$f"; log "Removed legacy file $f"; }
done
 
import_key() { # $1 = key URL, $2 = keyring path
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$1" -o "$tmp" || { rm -f "$tmp"; return 1; }
  if $DRY_RUN; then echo "[DRY-RUN] install key $1 -> $2"; rm -f "$tmp"; return 0; fi
  gpg --batch --yes --dearmor -o "$2" "$tmp" && chmod 644 "$2"
  local rc=$?; rm -f "$tmp"; return $rc
}
 
# Always refresh keys to pick up Microsoft key rotations
import_key "$MS_BASE/keys/microsoft.asc" "$KEY_LEGACY" || fail 8 "Could not import Microsoft key."
if [[ "$INTUNE_KEY" == "$KEY_2025" ]]; then
  import_key "$MS_BASE/keys/microsoft-2025.asc" "$KEY_2025" || fail 8 "Could not import microsoft-2025 key."
fi
log "Microsoft signing keys imported."
 
# Only add our repo files if the admin hasn't already enrolled these repos elsewhere
repo_enrolled_elsewhere() { # $1 = URL fragment, $2 = our file name
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" && "$(basename "$f")" != "$2" ]] || continue
    grep -v '^[[:space:]]*#' "$f" | grep -qF "$1" && return 0
  done
  return 1
}
 
INTUNE_LIST="microsoft-prod.list"
if repo_enrolled_elsewhere "packages.microsoft.com/ubuntu/$VERSION_ID/prod" "$INTUNE_LIST"; then
  log "Microsoft Ubuntu repo already configured elsewhere. Skipping."
  run rm -f "/etc/apt/sources.list.d/$INTUNE_LIST"
else
  $DRY_RUN || echo "deb [arch=amd64 signed-by=$INTUNE_KEY] $INTUNE_REPO_URL $VERSION_CODENAME main" \
    > "/etc/apt/sources.list.d/$INTUNE_LIST" || fail 8 "Could not write Intune repo file."
  log "Intune repo: $INTUNE_REPO_URL ($VERSION_CODENAME), key $(basename "$INTUNE_KEY")"
fi
 
# Edge's own installer may add microsoft-edge-*.list duplicates; keep exactly one
for f in /etc/apt/sources.list.d/microsoft-edge-*.list; do [[ -f "$f" ]] && run rm -f "$f"; done
if repo_enrolled_elsewhere "packages.microsoft.com/repos/edge" "microsoft-edge.list"; then
  log "Edge repo already configured elsewhere. Skipping."
else
  $DRY_RUN || echo "deb [arch=amd64 signed-by=$KEY_LEGACY] $MS_BASE/repos/edge stable main" \
    > /etc/apt/sources.list.d/microsoft-edge.list || fail 8 "Could not write Edge repo file."
  log "Edge repo configured (legacy key)."
fi
 
run "${APT[@]}" update || fail 8 "apt update failed after adding Microsoft repos (check for NO_PUBKEY above)."
 
# ---------------------------------------------------------------------------- 8. Edge + Intune
step "Microsoft Edge and Intune Portal"
if is_installed microsoft-edge-stable; then
  log "Microsoft Edge already installed. Checking for updates..."
  run "${APT[@]}" install --only-upgrade microsoft-edge-stable || warn "Edge update check failed."
else
  run "${APT[@]}" install microsoft-edge-stable || fail 9 "Microsoft Edge install failed."
fi
for f in /etc/apt/sources.list.d/microsoft-edge-*.list; do [[ -f "$f" ]] && run rm -f "$f"; done
 
if is_installed intune-portal; then
  log "Intune Portal already installed. Checking for updates..."
  run "${APT[@]}" install --only-upgrade intune-portal || warn "Intune Portal update check failed."
else
  run "${APT[@]}" install intune-portal || fail 10 "Intune Portal install failed."
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
 
pkg_ver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo "n/a"; }
step "Summary"
log "OS:              $PRETTY_NAME"
log "Azure VM:        $IS_AZURE"
log "Microsoft Edge:  $(pkg_ver microsoft-edge-stable)"
log "Intune Portal:   $(pkg_ver intune-portal)"
log "Intune repo key: $(basename "$INTUNE_KEY")"
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
if [[ "$TARGET_USER" != "root" ]] && ! passwd -S "$TARGET_USER" 2>/dev/null | awk '{exit !($2=="P" || $2=="PS")}'; then
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
