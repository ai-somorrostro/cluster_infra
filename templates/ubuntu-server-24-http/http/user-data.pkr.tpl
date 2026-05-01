#cloud-config
autoinstall:
  version: 1
  refresh-installer:
    update: true
  shutdown: reboot
  locale: en_US.UTF-8
  keyboard:
    layout: es
  timezone: Europe/Madrid
  updates: security
  storage:
    layout:
      name: lvm
      match:
        size: largest
  identity:
    hostname: ubuntu-template
    username: ${ssh_username}
    password: ${ssh_password_hash}
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - ${ssh_public_key}
  packages:
    - qemu-guest-agent
  late-commands:
    - echo '${ssh_username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${ssh_username}
    - chmod 440 /target/etc/sudoers.d/${ssh_username}
    - curtin in-target --target=/target -- systemctl enable qemu-guest-agent
