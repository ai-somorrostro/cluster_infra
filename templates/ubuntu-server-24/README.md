# ubuntu-server-24

Packer template for Ubuntu Server 24.04 LTS on Proxmox VE.

## What's included

- User `telecomunicaciones` with sudo, SSH key, and password
- Docker CE + Compose plugin (official repo)
- uv, git, htop, vim, jq, curl, wget, net-tools, dnsutils, nfs-common
- fail2ban, unattended-upgrades
- qemu-guest-agent
- Timezone: Europe/Madrid
- Root SSH login disabled
- Proxmox cloud-init drive (set hostname, user, SSH key at clone time)

## Setup

```bash
cp variables.pkrvars.hcl.example variables.pkrvars.hcl   # fill in secrets
cp http/user-data.example http/user-data                  # fill in password hash + SSH key
```

Generate password hash:
```bash
openssl passwd -6 'yourpassword'
```

Fill `Makefile` header: `PROXMOX_HOST`, `BUILD_ID`, `TEMPLATE_ID`.

## Usage

```bash
make init        # download Proxmox plugin (once)
make build       # build template on local-lvm (~10 min)
make distribute  # clone to ssd-data, destroy build VM
```

## Files

| File | Purpose |
|---|---|
| `ubuntu-server-24.pkr.hcl` | Packer build definition |
| `variables.pkrvars.hcl` | Secrets — gitignored, fill this in |
| `variables.pkrvars.hcl.example` | Safe-to-commit template |
| `http/user-data` | Autoinstall config — gitignored |
| `http/user-data.example` | Safe-to-commit template |
| `http/meta-data` | Required empty file for cloud-init |
| `scripts/` | Provisioner scripts (packages, Docker, uv, cleanup) |
| `TROUBLESHOOTING.md` | Known issues and fixes |
