#!/bin/bash
#################################################################################################
# Author: Nicholas Fisher
# Date: October 10th 2026
# Description of Script
# This Bash script prepares an Azure VM running Ubuntu 22.04 for Microsoft Intune enrollment.
# It checks if GNOME is already running and if not, installs a minimal GNOME desktop environment
# with XRDP for remote desktop access, then configures the XRDP session to load the Ubuntu GNOME
# desktop with the dock and taskbar intact. After a reboot, it installs prerequisite packages,
# Microsoft Edge stable, and the Intune Portal app using the official Microsoft package
# repositories with signed GPG keys. After the final reboot, sign into Edge with your domain
# account first, then open the Intune Portal app to complete enrollment.
#################################################################################################

# Check if GNOME is already the active desktop session
if [ "${XDG_CURRENT_DESKTOP:-}" != "GNOME" ] && [ "${XDG_CURRENT_DESKTOP:-}" != "ubuntu:GNOME" ]; then
    echo "GNOME not detected. Installing and configuring GNOME + XRDP..."

    # Install GNOME minimal desktop, Flashback session, XRDP, and required display/session dependencies
    sudo apt update
    sudo apt install -y ubuntu-desktop-minimal gnome-session-flashback metacity xrdp xorgxrdp dbus-x11

    # Enable and start XRDP service, then add xrdp user to ssl-cert group for certificate access
    sudo systemctl enable --now xrdp
    sudo adduser xrdp ssl-cert

    # XRDP session fix: force Ubuntu GNOME session so the dock and taskbar load correctly over RDP
    # Step 1: Set GNOME as the default session for XRDP
    echo "gnome-session" > "$HOME/.xsession"

    # Step 2: Write session environment variables so XRDP launches ubuntu:GNOME with correct appearance
    cat > "$HOME/.xsessionrc" <<- "EOF"
export XAUTHORITY=${HOME}/.Xauthority
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
EOF

    # Restart XRDP to apply session changes
    sudo systemctl restart xrdp
    echo "GNOME installation/config complete. System will reboot at end."
else
    echo "GNOME already running."
fi

# Install prerequisite packages needed for adding Microsoft repositories
sudo apt update
sudo apt install -y curl gpg ca-certificates

# Reboot to apply desktop/XRDP changes before proceeding with software installation
sudo reboot

# ===== Run the following after reboot =====

# Add the Microsoft GPG key to the system keyring for package signature verification
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft.gpg

# Add the Microsoft Edge stable repository and install Microsoft Edge
sudo sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main" > /etc/apt/sources.list.d/microsoft-edge.list'
sudo apt update
sudo apt install -y microsoft-edge-stable

# Add the Microsoft Intune repository using the same GPG key, then install the Intune Portal app
sudo sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main" > /etc/apt/sources.list.d/microsoft-ubuntu-jammy-prod.list'
sudo apt update
sudo apt install -y intune-portal

# Reboot to finalize all installations before enrollment
# After reboot: sign into Edge with your domain account first, then open the Intune Portal app to complete enrollment
echo "Rebooting system..."
sudo reboot
