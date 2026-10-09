cat > intune-prep-rhel-v1.sh << 'EOF'
#!/bin/bash
#################################################################################################
# Author: Nicholas Fisher
# Date: October 10th 2026
# Description of Script
# This Bash script prepares a physical device running RHEL 8/9 for Microsoft Intune enrollment.
# It checks if GNOME is running and installs it if not, installs Microsoft Edge and the Intune
# Portal app, then reboots the machine.
# After reboot, sign into Edge with your domain account first, then open the Intune Portal app
# to complete enrollment.
#################################################################################################

# ===== Ensure GNOME is installed and active =====
if [[ "${XDG_CURRENT_DESKTOP:-}" != "GNOME" ]]; then
    echo "GNOME not detected. Installing and configuring GNOME..."
    sudo dnf -y update
    sudo dnf -y groupinstall "Server with GUI"
    # Install required display/session dependencies
    sudo dnf -y install \
        gnome-session \
        gnome-terminal \
        dbus-x11
    sudo systemctl set-default graphical.target
    echo "GNOME installation/config complete. System will reboot."
    sudo reboot
else
    echo "GNOME already running."
fi

# ===== Install prerequisites =====
sudo dnf -y install curl ca-certificates gnupg2

# ===== Add Microsoft GPG key and repository, then install Microsoft Edge stable =====
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo dnf config-manager --add-repo https://packages.microsoft.com/yumrepos/edge
sudo mv /etc/yum.repos.d/packages.microsoft.com_yumrepos_edge.repo /etc/yum.repos.d/microsoft-edge.repo
sudo dnf -y install microsoft-edge-stable

# ===== Add Microsoft GPG key and Intune repository, then install the Intune Portal app =====
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo dnf config-manager --add-repo https://packages.microsoft.com/yumrepos/microsoft-rhel9.0-prod
sudo dnf install intune-portal

# Reboot to apply all changes before enrollment
# After reboot: sign into Edge with your domain account first, then open the Intune Portal app to complete enrollment
sudo reboot
EOF
chmod +x intune-prep-rhel-v1.sh && ./intune-prep-rhel-v1.sh
