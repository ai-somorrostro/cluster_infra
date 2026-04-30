#!/bin/bash
set -euo pipefail

apt-get autoremove -y
apt-get autoclean -y
apt-get clean

# SSH host keys — regenerated unique per clone on first boot
rm -f /etc/ssh/ssh_host_*

# machine-id — each clone must get its own
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# cloud-init state — runs fresh on first boot of each clone
cloud-init clean --logs --seed

# Remove installer-generated cloud-init network override so Proxmox
# cloud-init can apply network settings on clone boot.
rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg

rm -f /root/.bash_history /home/telecomunicaciones/.bash_history
rm -rf /tmp/* /var/tmp/*
find /var/log -type f -exec truncate -s 0 {} \;

sync
