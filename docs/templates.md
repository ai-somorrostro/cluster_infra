# VM and container templates

| Template | Folder | Result |
|---|---|---|
| Ubuntu Server 24.04 LTS (Packer, HTTP autoinstall) | [`templates/VMs/ubuntu-server-24-http/`](../templates/VMs/ubuntu-server-24-http/README.md) | VM `9001` (`ubuntu-server-24`) on `ssd-data`, shared by all 3 nodes |
| Ubuntu LXC (pveam + Ansible) | [`templates/containers/ubuntu-lxc/`](../templates/containers/ubuntu-lxc/README.md) | CT template (`BUILD_VMID`, default 9000) |

Both read the Proxmox API credentials from the repo `.env` (`lib/pve-load-env.sh`), like the `vm/` scripts.

## Ubuntu 24.04 VM template

What it includes:

- Cloud-init with DHCP: hostname, user and SSH key set at clone time.
- Password expiration for the cloud-init user (`iab-expire-cloudinit-password`).
- The cluster MOTD (`motds/iab/`).
- **qemu-guest-agent**: required by every `vm/` script.
- Docker CE + Compose, `uv`, and the base packages from `scripts/install-packages.sh`.
- `cleanup.sh` empties `machine-id`, so every clone gets its own DHCP lease. That is why `vm_fix_netplan_dhcp.sh` is no longer needed.

Build:

```bash
cd templates/VMs/ubuntu-server-24-http
cp variables.pkrvars.example.hcl variables.pkrvars.hcl   # not committed
make init
make all     # build 9000 on local-lvm → full clone to 9001 on ssd-data → template
```

### Using the template

```bash
# Clone from the UI (full clone) or the API, then with the scripts:
vm/vm_change_hostname.sh 130:lab-01                       # hostname = VM name
vm/vm_create_users.sh --users users.txt 130
vm/vm_grow_fs.sh --size +20G 130                          # base disk is 32G (the LV uses half of it)
```

Things to know about the template's config:

- **Hostname:** `/etc/cloud/cloud.cfg.d/99-proxmox.cfg` has `preserve_hostname: false`, so cloud-init sets the hostname to the **VM name** on every boot. Name the VM properly when cloning, or use `vm_change_hostname.sh`.
- **SSH password login:** the template writes `PasswordAuthentication yes` to `sshd_config.d/99-custom.conf`, but sshd keeps the first value it reads and `50-cloud-init.conf` (`no`) comes first. `vm_create_users.sh` fixes it with a `01-password-auth.conf` drop-in. The template could do the same.

## Ubuntu LXC template

`build.sh`:

1. downloads a stock template with `pveam`;
2. creates a temporary CT and provisions it with `playbook.yml` (Ansible);
3. cleans it (SSH host keys, machine-id);
4. converts it with `pct template`.

It is idempotent: re-running destroys the previous build CT. Details in its [README](../templates/containers/ubuntu-lxc/README.md).

The `vm/` scripts only work on QEMU VMs: they report LXC containers as failed.

## Turning an existing VM into a template

```bash
vm/vm_to_template.sh --from local-lvm --to ssd-data 120:my-template
```
