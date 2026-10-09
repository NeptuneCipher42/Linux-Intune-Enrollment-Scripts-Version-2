#!/bin/bash
#################################################################################################
# Author: Nicholas Fisher
# Date: October 10 2026
# Description of Script
# This Bash script prepares an Azure VM running Ubuntu 22.04 for Microsoft Intune enrollment.
# It performs a full system update, installs a minimal GNOME desktop environment with XRDP
# for remote access, configures the XRDP session to load the Ubuntu GNOME desktop with the
# dock and taskbar, installs Microsoft Edge and the Intune Portal app, then reboots the machine.
# After reboot, sign into Edge with your domain account first, then open the Intune Portal app
# to complete enrollment.
#################################################################################################

# Perform a full system update and upgrade
sudo apt-get update && apt-get full-upgrade -y

# Install GNOME minimal desktop, Flashback session, XRDP, and required display/session dependencies
sudo apt-get install -y ubuntu-desktop-minimal gnome-session-flashback metacity xrdp xorgxrdp dbus-x11

# Enable and start XRDP service, then add xrdp user to ssl-cert group for certificate access
sudo systemctl enable --now xrdp
sudo adduser xrdp ssl-cert

# If the taskbar does not load in Ubuntu Desktop LTS 22.04/24.04, run the following block and comment out the XRDP session fix below
# Note: Forcing the session via .xsessionrc can cause issues on Azure VMs - use only if taskbar is missing after trying the fix below
# cat > "$HOME/.xsessionrc" << "EOF"
# export XAUTHORITY=${HOME}/.Xauthority
# export GNOME_SHELL_SESSION_MODE=ubuntu
# export XDG_CURRENT_DESKTOP=ubuntu:GNOME
# export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
# EOF

# XRDP session fix: force Ubuntu GNOME session so the dock and taskbar load correctly over RDP
echo "gnome-session" > "$HOME/.xsession"
sudo systemctl restart xrdp

# Add Microsoft GPG key and repository, then install Microsoft Edge stable
sudo curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
sudo install -o root -g root -m 644 microsoft.gpg /etc/apt/trusted.gpg.d/
sudo sh -c 'echo "deb [arch=amd64] https://packages.microsoft.com/repos/edge stable main" > /etc/apt/sources.list.d/microsoft-edge-dev.list'
sudo rm microsoft.gpg
sudo apt update && sudo apt install microsoft-edge-stable

# Add Microsoft GPG key and Intune repository, then install the Intune Portal app
sudo curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
sudo install -o root -g root -m 644 microsoft.gpg /usr/share/keyrings/
rm microsoft.gpg
sudo sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/22.04/prod jammy main" > /etc/apt/sources.list.d/microsoft-ubuntu-jammy-prod.list'
sudo apt-get update
sudo apt install -y intune-portal

# Reboot to apply all changes before enrollment
echo "After reboot: sign into Edge with your licensed entra account first, then open the Intune Portal app to complete enrollment"
sudo reboot
