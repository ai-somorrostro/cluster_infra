#!/bin/bash
set -euo pipefail

timedatectl set-timezone Europe/Madrid

# Disable root SSH login
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# Override cloud-init SSH config which sets PasswordAuthentication no
echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/99-custom.conf

# Allow cloud-init to set hostname from Proxmox VM name on each clone
echo "preserve_hostname: false" > /etc/cloud/cloud.cfg.d/99-proxmox.cfg

systemctl enable fail2ban
systemctl enable unattended-upgrades
