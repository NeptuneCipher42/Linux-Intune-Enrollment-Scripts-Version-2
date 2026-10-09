#!/usr/bin/env bash
#################################################################################################
# Ubuntu Intune Enrollment Prep - Azure VM (Legacy: Ubuntu 22.04 / 24.04)
# Author:  Nicholas Fisher
# Version: 2.2 (legacy branch)
# Date:    October 10th 2026
#
# Prepares an Azure VM running Ubuntu 22.04 or 24.04 LTS for Microsoft Intune enrollment
# using GNOME + xrdp. For Ubuntu 26.04+ use the v3 script: GNOME 49+ removed X11 sessions,
# so xrdp can no longer start GNOME on newer releases.
#
# What it does (one run, no mid-script reboot):
#   1. Checks root, Ubuntu version (22.04 / 24.04), architecture and internet access
#   2. Waits for cloud-init, then updates the system
#   3. Installs a minimal GNOME desktop + Flashback session if GNOME is not installed
#      (detected from installed packages, which works over SSH unlike $XDG_CURRENT_DESKTOP)
#   4. Installs and configures xrdp:
#        - adds xrdp to the ssl-cert group for certificate access
#        - .xsession -> gnome-session, and .xsessionrc forcing the ubuntu:GNOME session mode
#          so the dock and taskbar load over RDP (for your user and /etc/skel)
#        - unlocks the GNOME keyring at RDP login so the Intune/Entra sign-in can save credentials
#        - opens 3389/tcp in UFW if UFW is active
#   5. Adds the Microsoft Edge and Intune repositories (signed key, release detected
#      automatically), then installs Microsoft Edge and the Intune Portal app
#   6. Verifies everything and reboots
#
# Safe to re-run: completed steps are detected and skipped.
#
# NOTE: Microsoft's current Intune supported list is Ubuntu 24.04 and 26.04. Ubuntu 22.04
# still installs from Microsoft's repo but is no longer officially supported.
#
# After reboot: RDP in, sign into Microsoft Edge with your work account FIRST, then open the
# Intune Portal app to enroll. Skipping the Edge sign-in causes error 4ulu5.
#
# Usage:   sudo ./Ubuntu-Legacy-Azure-VM-Enrollment-22.04-24.04.sh [--no-reboot]
# Log:     /var/log/intune-enrollment-prep.log
#
# Exit codes:
#   0  Success
#   1  Not run as root / bad arguments
#   2  Unsupported OS, release or architecture
#   3  Cannot reach packages.microsoft.com
#   4  System update or prerequisite install failed
#   5  Desktop or xrdp setup failed
#   6  Microsoft key or repository setup failed
#   7  Microsoft Edge install failed
#   8  Intune Portal install failed
#   9  Final verification failed
#################################################################################################

set -uo pipefail

LOG_FILE="/var/log/intune-enrollment-prep.log"
MS_BASE="https://packages.microsoft.com"
MS_KEYRING="/usr/share/keyrings/microsoft.gpg"
LEGACY_RELEASES=("22.04" "24.04")
DO_REBOOT=true
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o DPkg::Lock::Timeout=600)

case "${1:-}" in
  "")           ;;
  --no-reboot)  DO_REBOOT=false ;;
  -h|--help)    sed -n '/^# Usage:/,/^# Log:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)            echo "Unknown option: $1 (use --no-reboot or --help)"; exit 1 ;;
esac

log()  { echo "[$(date '+%F %T')] [INFO]  $*"; }
warn() { echo "[$(date '+%F %T')] [WARN]  $*"; }
fail() { echo "[$(date '+%F %T')] [ERROR] $2 (exit code $1)"; exit "$1"; }
is_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# ---------------------------------------------------------------- 1. Checks
[[ $EUID -eq 0 ]] || { echo "Run this script with sudo."; exit 1; }
exec > >(tee -a "$LOG_FILE") 2>&1
log "===== Intune enrollment prep (Azure VM, legacy 22.04/24.04) started ====="

# The desktop user is whoever ran sudo, not root
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ "$TARGET_USER" == "root" ]] && warn "Run with sudo from your normal account so the RDP session files go to that user."

# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail 2 "This script is for Ubuntu. Detected: ${PRETTY_NAME:-unknown}"
SUPPORTED=false
for r in "${LEGACY_RELEASES[@]}"; do [[ "$VERSION_ID" == "$r" ]] && SUPPORTED=true; done
$SUPPORTED || fail 2 "This legacy script supports Ubuntu 22.04 and 24.04 only. Detected $VERSION_ID. Use the v3 script for 26.04+."
[[ "$VERSION_ID" == "22.04" ]] && warn "Ubuntu 22.04 is no longer on Microsoft's Intune supported list. Plan an upgrade to 24.04."

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || fail 2 "Edge and Intune Portal require amd64. Detected: $ARCH"
log "Detected $PRETTY_NAME ($VERSION_CODENAME, $ARCH). Desktop user: $TARGET_USER"

command -v curl >/dev/null || "${APT[@]}" install curl || fail 4 "Could not install curl."
curl -fsS --max-time 15 -o /dev/null "$MS_BASE/keys/microsoft.asc" \
  || fail 3 "Cannot reach $MS_BASE. Check outbound internet / NSG / proxy."

# Azure: cloud-init may still be running apt on first boot
if command -v cloud-init >/dev/null; then
  log "Waiting for cloud-init to finish (if running)..."
  cloud-init status --wait >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- 2. Update + prerequisites
log "Updating system packages..."
"${APT[@]}" update && "${APT[@]}" full-upgrade || fail 4 "System update failed."
"${APT[@]}" install curl gpg ca-certificates || fail 4 "Failed to install prerequisites."

# ---------------------------------------------------------------- 3. GNOME desktop
# Package check instead of $XDG_CURRENT_DESKTOP: that variable is empty over SSH/sudo,
# which made the old check reinstall the desktop on every run.
if is_installed ubuntu-desktop-minimal || is_installed ubuntu-desktop; then
  log "GNOME desktop already installed. Skipping."
else
  log "Installing minimal GNOME desktop + Flashback session (this takes a while)..."
  "${APT[@]}" install ubuntu-desktop-minimal gnome-session-flashback metacity dbus-x11 \
    || fail 5 "GNOME desktop install failed."
fi
systemctl set-default graphical.target >/dev/null || fail 5 "Could not set graphical boot target."

# ---------------------------------------------------------------- 4. xrdp
if is_installed xrdp && is_installed xorgxrdp; then
  log "xrdp already installed. Skipping."
else
  log "Installing xrdp..."
  "${APT[@]}" install xrdp xorgxrdp dbus-x11 || fail 5 "xrdp install failed."
fi

# Certificate access for xrdp
id -nG xrdp | grep -qw ssl-cert || adduser xrdp ssl-cert || fail 5 "Could not add xrdp to ssl-cert."

# XRDP session fix: force the Ubuntu GNOME session so the dock and taskbar load over RDP.
# Written for the desktop user and /etc/skel so future users get it too.
for dir in "$TARGET_HOME" /etc/skel; do
  # Step 1: GNOME as the default xrdp session
  if [[ "$(cat "$dir/.xsession" 2>/dev/null)" != "gnome-session" ]]; then
    echo "gnome-session" > "$dir/.xsession" || fail 5 "Could not write $dir/.xsession."
    log "Wrote $dir/.xsession"
  fi
  # Step 2: session variables so xrdp launches ubuntu:GNOME with the correct appearance
  if ! grep -q "GNOME_SHELL_SESSION_MODE=ubuntu" "$dir/.xsessionrc" 2>/dev/null; then
    cat > "$dir/.xsessionrc" <<'EOF' || fail 5 "Could not write $dir/.xsessionrc."
export XAUTHORITY=${HOME}/.Xauthority
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
EOF
    log "Wrote $dir/.xsessionrc"
  fi
done
chown "$TARGET_USER:" "$TARGET_HOME/.xsession" "$TARGET_HOME/.xsessionrc"

# Unlock the GNOME keyring at RDP login (from Microsoft's Azure VM guide). Without this the
# Intune/Entra sign-in often never shows the password prompt over RDP.
PAM_FILE="/etc/pam.d/xrdp-sesman"
if grep -q "pam_gnome_keyring.so" "$PAM_FILE" 2>/dev/null; then
  log "GNOME keyring already unlocked by xrdp PAM. Skipping."
else
  cp -n "$PAM_FILE" "$PAM_FILE.bak"
  echo "auth    optional        pam_gnome_keyring.so" >> "$PAM_FILE"
  echo "session optional        pam_gnome_keyring.so auto_start" >> "$PAM_FILE"
  log "Added GNOME keyring unlock to $PAM_FILE (backup: $PAM_FILE.bak)."
fi

# GNOME Remote Desktop (24.04) also wants port 3389; keep xrdp as the only listener
systemctl disable --now gnome-remote-desktop.service >/dev/null 2>&1 || true
systemctl enable xrdp >/dev/null || fail 5 "Could not enable xrdp."
systemctl restart xrdp || fail 5 "Could not restart xrdp."

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 3389/tcp >/dev/null && log "UFW active: allowed 3389/tcp."
fi

# ---------------------------------------------------------------- 5. Microsoft repos
# Remove older repo files that cause "conflicting Signed-By" apt errors
rm -f /etc/apt/sources.list.d/microsoft-edge-dev.list \
      /etc/apt/sources.list.d/microsoft-ubuntu-*-prod.list \
      /etc/apt/trusted.gpg.d/microsoft.gpg

# Always refresh the key so Microsoft key rotations are picked up
curl -fsSL "$MS_BASE/keys/microsoft.asc" | gpg --batch --yes --dearmor -o "$MS_KEYRING" \
  || fail 6 "Could not import Microsoft GPG key."
chmod 644 "$MS_KEYRING"

echo "deb [arch=amd64 signed-by=$MS_KEYRING] $MS_BASE/repos/edge stable main" \
  > /etc/apt/sources.list.d/microsoft-edge.list
echo "deb [arch=amd64 signed-by=$MS_KEYRING] $MS_BASE/ubuntu/$VERSION_ID/prod $VERSION_CODENAME main" \
  > /etc/apt/sources.list.d/microsoft-prod.list
"${APT[@]}" update || fail 6 "apt update failed after adding Microsoft repos."
log "Microsoft repos configured (Intune repo: ubuntu/$VERSION_ID/$VERSION_CODENAME)."

# ---------------------------------------------------------------- 6. Edge + Intune Portal
if is_installed microsoft-edge-stable; then
  log "Microsoft Edge already installed. Skipping."
else
  "${APT[@]}" install microsoft-edge-stable || fail 7 "Microsoft Edge install failed."
fi
# Edge's installer can add a duplicate repo file; keep only ours
rm -f /etc/apt/sources.list.d/microsoft-edge-*.list

if is_installed intune-portal; then
  log "Intune Portal already installed. Skipping."
else
  "${APT[@]}" install intune-portal || fail 8 "Intune Portal install failed."
fi

# ---------------------------------------------------------------- 7. Verify + reboot
is_installed microsoft-edge-stable || fail 9 "Edge not detected after install."
is_installed intune-portal        || fail 9 "Intune Portal not detected after install."
systemctl is-active --quiet xrdp  || fail 9 "xrdp is not running."

log "All components installed and verified."
log "Azure: allow 3389 in the NSG, or connect through Azure Bastion (Standard SKU) over RDP."
if [[ "$TARGET_USER" != "root" ]] && ! passwd -S "$TARGET_USER" 2>/dev/null | awk '{exit !($2=="P")}'; then
  warn "$TARGET_USER has no password (common on SSH-key Azure VMs). RDP needs one: sudo passwd $TARGET_USER"
fi
log "NEXT: RDP in as $TARGET_USER, sign into Edge first, then open Intune Portal to enroll."

if $DO_REBOOT; then
  log "Rebooting in 10 seconds (Ctrl+C to cancel)..."
  sleep 10
  reboot
else
  log "--no-reboot set. Reboot manually before enrolling."
fi
exit 0
