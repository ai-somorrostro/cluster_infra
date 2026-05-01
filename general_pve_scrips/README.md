# general_pve_scrips

Proxmox automation scripts designed to run from the `provisioner` or from any
machine/container with HTTPS access to the Proxmox API.

## Credentials

The recommended path is a local `.env` file in the repository root. Scripts load
it automatically:

```dotenv
PROXMOX_API_URL=https://192.168.136.238:8006/api2/json
PROXMOX_API_TOKEN_ID=root@pam!infra
PROXMOX_API_TOKEN_SECRET=secret
```

Do not commit that file. The repository root ignores `.env`.

With that file in place, run scripts directly:

```bash
./general_pve_scrips/vm_apt_install.sh 100 -- vim curl
```

From Docker/provisioner:

```bash
docker run --rm --env-file .env provisioner \
  ./general_pve_scrips/vm_apt_install.sh 100 -- vim curl
```

You can also export variables manually:

```bash
export PROXMOX_API_URL="https://192.168.136.238:8006/api2/json"
export PROXMOX_API_TOKEN_ID="root@pam!infra"
export PROXMOX_API_TOKEN_SECRET="secret"
```

To use another file instead of `.env`:

```bash
PROXMOX_ENV_FILE=/run/secrets/proxmox.env ./general_pve_scrips/vm_apt_install.sh 100 -- vim
```

You can also reuse a Packer-style file:

```bash
VARS_FILE=../templates/ubuntu-server-24-http/variables.pkrvars.hcl ./vm_apt_install.sh 100 -- vim
```

The file must contain:

```hcl
proxmox_api_url          = "https://pve:8006/api2/json"
proxmox_api_token_id     = "user@realm!token"
proxmox_api_token_secret = "secret"
```

## Scripts Ported To The API

```bash
./vm_apt_install.sh 100 101 -- vim curl htop
./vm_apt_install.sh --with-docker 100 -- git make
```

This script no longer requires local `pvesh` or `qm`. It uses:

- Proxmox API to detect the node, status, and VM.
- QEMU guest-agent API to run commands inside the VM.

The VM must be `running`, qemu guest agent must be enabled in Proxmox, and the
guest-agent service must be running inside the operating system.

## Pending Port

The remaining scripts may still assume execution from a Proxmox node until they
are migrated to `../lib/proxmox-api.sh`.

Suggested priority:

1. `vm_create_users.sh`
2. `vm_change_hostname.sh`
3. `vm_fix_netplan_dhcp.sh`
4. `install_pip_cache.sh`
5. `resize_vm.sh`
6. `vm_watchdog.sh`
7. `vm_to_template.sh`
8. `vm_enable_external_vnc.sh`

For VNC runtime passwords and some disk move operations, an SSH fallback to the
node may be required if your Proxmox version does not expose the exact operation
through the API.
