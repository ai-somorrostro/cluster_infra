# ubuntu-server-24-http

Ubuntu Server 24.04 template for Proxmox built with Packer autoinstall over Packer's HTTP server.

Prerequisites:
ubuntu-server iso file in storage:iso/ubuntu-24.04.3-live-server-amd64.iso

features of the template:
- Ubuntu Server 24.04 LTS
- HTTP autoinstall
- Cloud-init
- DHCP
- password expiration
- custom MOTD

## Build

```bash
cp variables.pkrvars.example.hcl variables.pkrvars.hcl
make init
make all
```

`make all` does:

1. Build temporary template `9000` on `local-lvm`.
2. Set Proxmox cloud-init DHCP metadata on `9000`.
3. Replace final template `9001` with a full clone on `ssd-data`.
4. Set DHCP metadata on `9001`.
5. Convert `9001` to template.

## Build Only

To create only the Packer template `9000`, without cloning it to `9001`:

```bash
make build
make dhcp
```

That leaves:

```text
9000 ubuntu-server-24-http
storage: local-lvm
cloud-init: ip=dhcp
```

## Clone A VM

Clone from template `9001` and keep Cloud-Init IP config as DHCP:

```bash
qm clone 9001 110 --name my-vm --full 1 --storage ssd-vms
qm set 110 --ipconfig0 ip=dhcp
qm start 110
```

## MOTD

Dynamic MOTD scripts live in `../../motds/`.

The build installs:

```bash
/etc/update-motd.d/10-iab-cluster
/etc/iab-cluster/banner.txt
```

It also disables the default Ubuntu MOTD scripts so the login banner only shows the IAB cluster MOTD.
