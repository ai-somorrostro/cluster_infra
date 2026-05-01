#!/usr/bin/env bash
set -euo pipefail

timedatectl set-timezone Europe/Madrid

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/99-custom.conf

echo "preserve_hostname: false" > /etc/cloud/cloud.cfg.d/99-proxmox.cfg

systemctl enable fail2ban
systemctl enable unattended-upgrades
