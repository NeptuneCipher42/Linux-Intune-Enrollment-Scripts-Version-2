cat > test.sh << 'EOF'
#!/bin/bash
#################################################################################################
# Author: Nicholas Fisher
# Date: October 10th 2026
# Description of Script
# This Bash script prepares an Azure VM running RHEL 8/9 for Microsoft Intune enrollment.
# It installs EPEL, xrdp, tigervnc-server, opens the firewall port, then installs
# Microsoft Edge and the Intune Portal app, and reboots the machine.
# After reboot, sign into Edge with your domain account first, then open the Intune Portal
# app to complete enrollment.
#################################################################################################

# ===== Step 1: Install EPEL (required for xrdp on RHEL 9) =====
sudo dnf install -y epel-release || \
    sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# ===== Step 2: Install xrdp and tigervnc-server =====
sudo dnf install xrdp tigervnc-server -y

# ===== Step 3: Start and enable xrdp =====
sudo systemctl start xrdp
sudo systemctl enable xrdp

# ===== Step 4: Open firewall port 3389 =====
sudo firewall-cmd --add-port=3389/tcp --permanent
sudo firewall-cmd --reload

# ===== Install prerequisites =====
sudo dnf -y install curl ca-certificates gnupg2

# ===== Add Microsoft GPG key and repository, then install Microsoft Edge stable =====
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo dnf config-manager --add-repo https://packages.microsoft.com/yumrepos/edge
sudo mv /etc/yum.repos.d/packages.microsoft.com_yumrepos_edge.repo /etc/yum.repos.d/microsoft-edge.repo
sudo dnf -y install microsoft-edge-stable

# ===== Add Intune repository, then install the Intune Portal app =====
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo dnf config-manager --add-repo https://packages.microsoft.com/yumrepos/microsoft-rhel9.0-prod
sudo dnf -y install intune-portal

# Reboot to apply all changes before enrollment
# After reboot: sign into Edge with your domain account first, then open the Intune Portal app
sudo reboot
EOF
chmod +x test.sh && ./test.sh
