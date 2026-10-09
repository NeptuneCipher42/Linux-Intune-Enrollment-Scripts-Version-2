<div align="center">
  
```
██╗     ██╗███╗   ██╗██╗   ██╗██╗  ██╗    ██╗███╗   ██╗████████╗██╗   ██╗███╗   ██╗███████╗
██║     ██║████╗  ██║██║   ██║╚██╗██╔╝    ██║████╗  ██║╚══██╔══╝██║   ██║████╗  ██║██╔════╝
██║     ██║██╔██╗ ██║██║   ██║ ╚███╔╝     ██║██╔██╗ ██║   ██║   ██║   ██║██╔██╗ ██║█████╗  
██║     ██║██║╚██╗██║██║   ██║ ██╔██╗     ██║██║╚██╗██║   ██║   ██║   ██║██║╚██╗██║██╔══╝  
███████╗██║██║ ╚████║╚██████╔╝██╔╝ ██╗    ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚████║███████╗
╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝  ╚═══╝╚══════╝

███████╗███╗   ██╗██████╗  ██████╗ ██╗     ██╗     ███╗   ███╗███████╗███╗   ██╗████████╗
██╔════╝████╗  ██║██╔══██╗██╔═══██╗██║     ██║     ████╗ ████║██╔════╝████╗  ██║╚══██╔══╝
█████╗  ██╔██╗ ██║██████╔╝██║   ██║██║     ██║     ██╔████╔██║█████╗  ██╔██╗ ██║   ██║   
██╔══╝  ██║╚██╗██║██╔══██╗██║   ██║██║     ██║     ██║╚██╔╝██║██╔══╝  ██║╚██╗██║   ██║   
███████╗██║ ╚████║██║  ██║╚██████╔╝███████╗███████╗██║ ╚═╝ ██║███████╗██║ ╚████║   ██║   
╚══════╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚══════╝╚═╝     ╚═╝╚══════╝╚═╝  ╚═══╝   ╚═╝   

███████╗ ██████╗██████╗ ██╗██████╗ ████████╗███████╗
██╔════╝██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝██╔════╝
███████╗██║     ██████╔╝██║██████╔╝   ██║   ███████╗
╚════██║██║     ██╔══██╗██║██╔═══╝    ██║   ╚════██║
███████║╚██████╗██║  ██║██║██║        ██║   ███████║
╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝   ╚══════╝
```

### Automated Bash scripts for enrolling Linux machines into Microsoft Intune Version 2

![Shell Script](https://img.shields.io/badge/Shell_Script-121011?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![Ubuntu](https://img.shields.io/badge/Ubuntu_22.04/24.04-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)
![Red Hat](https://img.shields.io/badge/Red_Hat_8/9-EE0000?style=for-the-badge&logo=redhat&logoColor=white)
![Azure](https://img.shields.io/badge/Azure-0089D6?style=for-the-badge&logo=microsoftazure&logoColor=white)
![Microsoft Intune](https://img.shields.io/badge/Microsoft_Intune-0078D4?style=for-the-badge&logo=microsoft&logoColor=white)

</div>

---

## 📋 Table of Contents

- [Overview](#overview)
- [Scripts](#scripts)
  - [Ubuntu LTS](#ubuntu-lts)
  - [Red Hat](#red-hat)
- [Requirements](#requirements)
- [Usage](#usage)
- [Post-Enrollment Steps](#post-enrollment-steps)
- [Notes & Troubleshooting](#notes--troubleshooting)
- [Author](#author)

---

## Overview

A collection of Bash scripts that fully automate the setup process for enrolling Linux machines into **Microsoft Intune**. Each script is purpose-built for a specific distro and deployment type, handling everything from desktop environment installation and XRDP configuration to Microsoft package repository setup and Intune Portal installation — with a single run.

**Important Note: Please run the Microsoft Edge App and complete edge setup prior to running the Intune App for Registration. Otherwise you will incur error: 4ulu5**

---

## Scripts

### Ubuntu LTS

<details>
<summary><b>🖥️ Ubuntu-LTS-Enrollment-Azure-VM.sh — Azure Virtual Machine</b></summary>

<br>

**Target:** Ubuntu 22.04 LTS running as an Azure Virtual Machine

**What it does:**
- Checks if GNOME is already the active desktop — installs it if not
- Installs a minimal GNOME desktop environment with XRDP for remote desktop access
- Configures the XRDP session so the Ubuntu dock and taskbar load correctly over RDP
- Adds official Microsoft repositories with signed GPG keys
- Installs **Microsoft Edge** (stable) and the **Intune Portal** app
- Reboots to finalize before enrollment

**After reboot:** Sign into Edge with your domain account first, then open the Intune Portal app to complete enrollment.

🔗 [View Script](https://github.com/NeptuneCipher42/Linux-Intune-Enrollment-Scripts/blob/main/Ubuntu-LTS-Enrollment-Azure-VM.sh)

</details>

---

<details>
<summary><b>🖥️ Ubuntu-LTS-Physical-Desktop-Enrollment.sh — Physical Desktop</b></summary>

<br>

**Target:** Ubuntu 22.04 LTS running on a physical desktop machine

**What it does:**
- Performs a full system update and upgrade
- Installs prerequisite packages (`curl`, `gpg`, `ca-certificates`)
- Adds official Microsoft Edge and Intune repositories using signed GPG keys
- Installs **Microsoft Edge** (stable) and the **Intune Portal** app
- Reboots to finalize before enrollment

**After reboot:** Sign into Edge with your domain account first, then open the Intune Portal app to complete enrollment.

🔗 [View Script](https://github.com/NeptuneCipher42/Linux-Intune-Enrollment-Scripts/blob/main/Ubuntu-LTS-Physical-Desktop-Enrollment.sh)

</details>

---

### Red Hat

<details>
<summary><b>🔴 RedHat-Enrollment-Azure-VM.sh — Azure Virtual Machine</b></summary>

<br>

**Target:** RHEL 8/9 running as an Azure Virtual Machine

**What it does:**
- Checks if GNOME is already the active desktop — installs it if not
- Installs GNOME desktop environment and XRDP for remote desktop access
- Configures the XRDP session so the GNOME desktop loads correctly over RDP
- Installs prerequisite packages (`curl`, `ca-certificates`, `gnupg2`)
- Adds official Microsoft repositories using signed GPG keys
- Installs **Microsoft Edge** (stable) and the **Intune Portal** app
- Reboots to finalize before enrollment

**After reboot:** Sign into Edge with your domain account first, then open the Intune Portal app to complete enrollment.

🔗 [View Script](https://github.com/NeptuneCipher42/Linux-Intune-Enrollment-Scripts/blob/main/RedHat-LTS-Enrollment-Azure-VM.sh)
</details>

---

<details>

<summary><b>🔴 RedHat-Physical-Desktop-Enrollment.sh — Physical Desktop</b></summary>

<br>

**Target:** RHEL 8/9 running on a physical desktop machine

**What it does:**
- Checks if GNOME is already the active desktop — installs it if not
- Installs GNOME desktop environment and sets it as the default graphical target
- Installs prerequisite packages (`curl`, `ca-certificates`, `gnupg2`)
- Adds official Microsoft repositories using signed GPG keys
- Installs **Microsoft Edge** (stable) and the **Intune Portal** app
- Reboots to finalize before enrollment

**After reboot:** Sign into Edge with your domain account first, then open the Intune Portal app to complete enrollment.

🔗 [View Script](https://github.com/NeptuneCipher42/Linux-Intune-Enrollment-Scripts/blob/main/RedHat-LTS-Physical-Desktop-Enrollment.sh)

</details>

---

## Requirements

| Requirement | Details |
|---|---|
| OS | Ubuntu 22.04 LTS or Red Hat (see script header) |
| Privileges | Must be run as `root` or with `sudo` |
| Network | Active internet connection required |
| Azure VMs | Inbound RDP port **3389** must be open in your NSG |
| Intune | Valid Microsoft Intune license and domain account required for enrollment |

---

## Usage

**1. Clone the repository**
```bash
git clone https://github.com/NeptuneCipher42/Linux-Intune-Enrollment-Scripts.git
cd Linux-Intune-Enrollment-Scripts
```

**2. Make the script executable**
```bash
chmod +x <script-name>.sh
```

**3. Run the script**
```bash
sudo ./<script-name>.sh
```

**4. Follow post-reboot instructions**

Some scripts reboot mid-way through installation. Read the script header and inline comments before running so you know which steps require manual action after reboot.

---

## Post-Enrollment Steps

After the final reboot on any script:

1. Open **Microsoft Edge** and sign in with your organizational domain account
2. Open the **Intune Portal** app
3. Follow the on-screen prompts to complete device enrollment
4. Verify the device appears in your [Microsoft Intune admin center](https://intune.microsoft.com)

---

## Notes & Troubleshooting

<details>
<summary><b>⚠️ Taskbar or dock not loading over RDP (Azure VMs)</b></summary>

<br>

If the Ubuntu taskbar or dock fails to load after running the script, you can force the session environment by writing to `.xsessionrc`. This block is included but commented out in the Azure VM scripts:

```bash
cat > "$HOME/.xsessionrc" << "EOF"
export XAUTHORITY=${HOME}/.Xauthority
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
EOF
```

> **Note:** Only use this if the standard XRDP session fix doesn't work. Forcing `.xsessionrc` can cause display issues on some Azure VM configurations.

</details>

<details>
<summary><b>ℹ️ Why the script reboots mid-way through</b></summary>

<br>

On Azure VM scripts, a reboot after the desktop/XRDP installation is required before installing Microsoft Edge and the Intune Portal. This ensures the new desktop session environment is fully initialized before the Microsoft repositories are configured. After the reboot, re-run the script — it will detect GNOME is already installed and skip that block automatically.

</details>

<details>
<summary><b>ℹ️ GPG key reuse between Edge and Intune repositories</b></summary>

<br>

Both the Microsoft Edge and Intune Portal repositories use the same Microsoft GPG key stored at `/usr/share/keyrings/microsoft.gpg`. The key only needs to be imported once. If you run into `NO_PUBKEY` errors, re-run the GPG import step:

```bash
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
```

</details>

---

## Author

**Nicholas Fisher**

[![GitHub](https://img.shields.io/badge/GitHub-NeptuneCipher42-181717?style=flat&logo=github&logoColor=white)](https://github.com/NeptuneCipher42)
