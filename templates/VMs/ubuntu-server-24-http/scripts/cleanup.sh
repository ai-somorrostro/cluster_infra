#!/usr/bin/env bash
set -euo pipefail

apt-get autoremove -y
apt-get autoclean -y
apt-get clean

rm -f /etc/ssh/ssh_host_*

truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

cloud-init clean --logs --seed
rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg

rm -f /root/.bash_history /home/telecomunicaciones/.bash_history
rm -rf /tmp/* /var/tmp/*
find /var/log -type f -exec truncate -s 0 {} \;

sync
