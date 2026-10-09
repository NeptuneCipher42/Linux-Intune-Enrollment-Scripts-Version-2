#!/usr/bin/env bash
#################################################################################################
# Author: Nicholas Fisher
# Version: 2.1
# Date: October 10th 2026
# Description:
# Prepares an Azure VM running Ubuntu LTS for Microsoft Intune enrollment.
# Detects the Ubuntu version at runtime, so it works on current and future LTS releases
# as soon as Microsoft publishes an Intune repo for them (falls back to the newest known repo
# if not). Installs a minimal GNOME desktop with XRDP, configures the RDP session so the dock
# and taskbar load, installs Microsoft Edge and the Intune Portal app, then reboots.
# Safe to re-run: completed steps are detected and skipped.
#
# After reboot: RDP in, sign into Edge with your work account FIRST, then open the
# Intune Portal app to enroll (skipping Edge sign-in causes error 4ulu5).
#
# Usage:   sudo ./Ubuntu-LTS-Enrollment-Azure-VM.sh [--no-reboot]
# Log:     /var/log/intune-enrollment-prep.log
#
# Exit codes:
#   0  Success
#   1  Not run as root
#   2  Unsupported OS or architecture
#   3  Cannot reach packages.microsoft.com
#   4  System update or prerequisite install failed
#   5  Desktop or XRDP setup failed
#   6  Microsoft key or repository setup failed
#   7  Microsoft Edge install failed
#   8  Intune Portal install failed
#################################################################################################

set -uo pipefail

LOG_FILE="/var/log/intune-enrollment-prep.log"
MS_BASE="https://packages.microsoft.com"
MS_KEYRING="/usr/share/keyrings/microsoft.gpg"
# Fallback Intune repos, newest first. Used only if this release has no repo yet.
FALLBACK_REPOS=("24.04:noble" "22.04:jammy")
DO_REBOOT=true
export DEBIAN_FRONTEND=noninteractive

[[ "${1:-}" == "--no-reboot" ]] && DO_REBOOT=false

log()  { echo "[$(date '+%F %T')] [INFO]  $*"; }
warn() { echo "[$(date '+%F %T')] [WARN]  $*"; }
fail() { echo "[$(date '+%F %T')] [ERROR] $2 (exit code $1)"; exit "$1"; }
is_installed() { dpkg -s "$1" &>/dev/null; }

# ---------------------------------------------------------------- 1. Root check
[[ $EUID -eq 0 ]] || { echo "Run this script with sudo."; exit 1; }
exec > >(tee -a "$LOG_FILE") 2>&1
log "===== Intune enrollment prep started ====="

# The desktop user is whoever ran sudo, not root
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

# ---------------------------------------------------------------- 2. OS detection
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail 2 "This script is for Ubuntu. Detected: ${PRETTY_NAME:-unknown}"
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || fail 2 "Edge and Intune Portal require amd64. Detected: $ARCH"
[[ "${VERSION:-}" == *LTS* ]] || warn "$PRETTY_NAME is not an LTS release. Intune only supports Ubuntu LTS."
log "Detected $PRETTY_NAME ($VERSION_CODENAME, $ARCH). Desktop user: $TARGET_USER"

# ---------------------------------------------------------------- 3. Update + prerequisites
log "Updating system packages..."
apt-get update -y && apt-get full-upgrade -y || fail 4 "System update failed."
apt-get install -y curl gpg ca-certificates || fail 4 "Failed to install prerequisites."

curl -fsS --max-time 15 -o /dev/null "$MS_BASE/keys/microsoft.asc" \
  || fail 3 "Cannot reach $MS_BASE. Check outbound internet / NSG / proxy."

# ---------------------------------------------------------------- 4. Desktop + XRDP
if is_installed ubuntu-desktop-minimal || is_installed ubuntu-desktop; then
  log "GNOME desktop already installed. Skipping."
else
  log "Installing minimal GNOME desktop (this takes a while)..."
  apt-get install -y ubuntu-desktop-minimal gnome-session-flashback metacity dbus-x11 \
    || fail 5 "GNOME desktop install failed."
fi

if is_installed xrdp && is_installed xorgxrdp; then
  log "XRDP already installed. Skipping."
else
  log "Installing XRDP..."
  apt-get install -y xrdp xorgxrdp || fail 5 "XRDP install failed."
fi

systemctl enable --now xrdp || fail 5 "Could not enable/start xrdp service."
id -nG xrdp | grep -qw ssl-cert || adduser xrdp ssl-cert || fail 5 "Could not add xrdp to ssl-cert."

XSESSION="$TARGET_HOME/.xsession"
if [[ "$(cat "$XSESSION" 2>/dev/null)" != "gnome-session" ]]; then
  echo "gnome-session" > "$XSESSION" && chown "$TARGET_USER:" "$XSESSION" \
    || fail 5 "Could not write $XSESSION."
  log "XRDP session set to gnome-session for $TARGET_USER."
else
  log "XRDP session already configured. Skipping."
fi
systemctl restart xrdp || fail 5 "Could not restart xrdp."

# ---------------------------------------------------------------- 5. Microsoft key + repos
# Clean up V1-style entries that cause "conflicting Signed-By" apt errors
rm -f /etc/apt/sources.list.d/microsoft-edge-dev.list \
      /etc/apt/sources.list.d/microsoft-ubuntu-*-prod.list \
      /etc/apt/trusted.gpg.d/microsoft.gpg

if [[ -s "$MS_KEYRING" ]]; then
  log "Microsoft GPG key already present. Skipping."
else
  curl -fsSL "$MS_BASE/keys/microsoft.asc" | gpg --batch --yes --dearmor -o "$MS_KEYRING" \
    || fail 6 "Could not import Microsoft GPG key."
  chmod 644 "$MS_KEYRING"
fi

# Use this release's Intune repo if Microsoft publishes one, otherwise fall back
INTUNE_REPO=""
for candidate in "$VERSION_ID:$VERSION_CODENAME" "${FALLBACK_REPOS[@]}"; do
  ver="${candidate%%:*}"; code="${candidate##*:}"
  if curl -fsS --max-time 15 -o /dev/null "$MS_BASE/ubuntu/$ver/prod/dists/$code/Release"; then
    INTUNE_REPO="$ver:$code"; break
  fi
done
[[ -n "$INTUNE_REPO" ]] || fail 6 "No usable Microsoft Ubuntu repo found."
REPO_VER="${INTUNE_REPO%%:*}"; REPO_CODE="${INTUNE_REPO##*:}"
[[ "$REPO_VER" == "$VERSION_ID" ]] \
  || warn "No Intune repo for $VERSION_ID yet. Using $REPO_VER ($REPO_CODE). Check Microsoft's supported platforms list."

echo "deb [arch=amd64 signed-by=$MS_KEYRING] $MS_BASE/repos/edge stable main" \
  > /etc/apt/sources.list.d/microsoft-edge.list
echo "deb [arch=amd64 signed-by=$MS_KEYRING] $MS_BASE/ubuntu/$REPO_VER/prod $REPO_CODE main" \
  > /etc/apt/sources.list.d/microsoft-prod.list
apt-get update -y || fail 6 "apt update failed after adding Microsoft repos."
log "Microsoft repos configured (Intune repo: $REPO_VER/$REPO_CODE)."

# ---------------------------------------------------------------- 6. Edge + Intune Portal
if is_installed microsoft-edge-stable; then
  log "Microsoft Edge already installed. Skipping."
else
  apt-get install -y microsoft-edge-stable || fail 7 "Microsoft Edge install failed."
fi

if is_installed intune-portal; then
  log "Intune Portal already installed. Skipping."
else
  apt-get install -y intune-portal || fail 8 "Intune Portal install failed."
fi

# ---------------------------------------------------------------- 7. Verify + reboot
is_installed microsoft-edge-stable || fail 7 "Edge not detected after install."
is_installed intune-portal        || fail 8 "Intune Portal not detected after install."
systemctl is-active --quiet xrdp  || fail 5 "xrdp is not running."

log "All components installed and verified."
log "NEXT: RDP in as $TARGET_USER, sign into Edge first, then open Intune Portal to enroll."

if $DO_REBOOT; then
  log "Rebooting in 10 seconds (Ctrl+C to cancel)..."
  sleep 10
  reboot
else
  log "--no-reboot set. Reboot manually before enrolling."
fi
exit 0
