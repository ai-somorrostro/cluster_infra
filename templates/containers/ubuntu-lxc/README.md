# Proxmox LXC Template PoC

Build a reusable Proxmox LXC template with your "to-go" software baked in, by:

1. Downloading a stock distro template via `pveam`
2. Spinning up a temporary CT from it
3. Provisioning that CT with Ansible
4. Sanitizing it and converting it into a Proxmox CT template via `pct template`

## Layout

```
.
├── build.sh             # host mode (runs on Proxmox node, uses pct/pveam)
├── build-remote.sh      # remote mode (runs from LXC/VM, uses Proxmox API)
├── playbook.yml         # what gets baked into the image
└── README.md
```

## Requirements (`build.sh`, run from LXC/VM or any machine with API access)

- `apt install ansible openssh-client curl python3`
- Proxmox API credentials in env or repo `.env`:
  - `PROXMOX_API_URL`
  - `PROXMOX_API_TOKEN_ID`
  - `PROXMOX_API_TOKEN_SECRET`
- Optional:
  - `PVE_NODE` (if omitted, first online node is selected)
  - `STOCK_FILE` (exact `vztmpl` filename; otherwise auto-matches `STOCK_TEMPLATE_NAME` inside `TEMPLATE_STORAGE`)

## Usage

```bash
chmod +x build.sh
./build.sh
```

Override defaults via env vars instead of editing the script:

```bash
BUILD_VMID=9001 \
STOCK_TEMPLATE_NAME=ubuntu-24.04-standard \
ROOTFS_STORAGE=local-zfs \
./build.sh
```

When it finishes you'll have a Proxmox template at `BUILD_VMID` (default 9000).

Clone it like any other template:

```bash
pct clone 9000 200 --hostname my-app --full
pct start 200
```

## Adding your own "to-go" software

Edit `playbook.yml` — there's a placeholder at the bottom of the
task list with commented-out examples (Docker, Node, Tailscale). Re-run
`build.sh` to rebuild the template; the script destroys the previous build
CT automatically so it's safe to run repeatedly.

## What the script does in 30 seconds

```
pveam download ──► pct create ──► pct start ──► [wait for IP]
                                                      │
                                              [bootstrap python+sshd]
                                                      │
                                                ansible-playbook
                                                      │
                                                 [cleanup]
                                                      │
                                              pct stop ──► pct template
```

## Notes / gotchas

- **Idempotent**: re-running destroys the existing build CT first.
- **Cleanup wipes `/etc/ssh/ssh_host_*` and `/etc/machine-id`** so each
  clone gets its own identity on first boot.
- The playbook creates an `admin` user with passwordless sudo + your SSH
  key. Root login over SSH still works during the build (it's destroyed
  along with the host keys before templating).
- `--features nesting=1` is set so you can install Docker inside the
  template if you want to. Drop it if you don't need it.
- For Ubuntu templates the playbook works as-is. For non-Debian-family
  distros (Alpine, Rocky, etc.), swap `ansible.builtin.apt` for the
  appropriate package module.
