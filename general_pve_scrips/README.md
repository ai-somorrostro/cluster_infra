# general_pve_scrips

Scripts de automatización Proxmox pensados para ejecutarse desde el `provisioner`
o desde cualquier máquina/container con acceso HTTPS a la API de Proxmox.

## Credenciales

La vía recomendada es usar un `.env` local en la raíz del repo:

```dotenv
PROXMOX_API_URL=https://192.168.136.238:8006/api2/json
PROXMOX_API_TOKEN_ID=root@pam!infra
PROXMOX_API_TOKEN_SECRET=secret
```

No commitees ese fichero. La raíz del repo ignora `.env`.

Para cargarlo en una shell:

```bash
set -a
source .env
set +a

./general_pve_scrips/vm_apt_install.sh 100 -- vim curl
```

Desde Docker/provisioner:

```bash
docker run --rm --env-file .env provisioner \
  ./general_pve_scrips/vm_apt_install.sh 100 -- vim curl
```

También puedes exportarlas a mano si prefieres:

```bash
export PROXMOX_API_URL="https://192.168.136.238:8006/api2/json"
export PROXMOX_API_TOKEN_ID="root@pam!infra"
export PROXMOX_API_TOKEN_SECRET="secret"
```

También se puede reutilizar un fichero estilo Packer:

```bash
VARS_FILE=../templates/ubuntu-server-24-http/variables.pkrvars.hcl ./vm_apt_install.sh 100 -- vim
```

El fichero debe contener:

```hcl
proxmox_api_url          = "https://pve:8006/api2/json"
proxmox_api_token_id     = "user@realm!token"
proxmox_api_token_secret = "secret"
```

## Scripts Portados A API

```bash
./vm_apt_install.sh 100 101 -- vim curl htop
./vm_apt_install.sh --with-docker 100 -- git make
```

Este script ya no requiere `pvesh` ni `qm` locales. Usa:

- API Proxmox para detectar nodo, estado y VM.
- QEMU guest-agent API para ejecutar comandos dentro de la VM.

La VM debe estar `running`, tener el qemu guest agent habilitado en Proxmox y el
servicio del guest agent levantado dentro del sistema operativo.

## Pendiente De Portar

Los demás scripts todavía pueden asumir ejecución desde un nodo Proxmox hasta que
se migren a `../lib/proxmox-api.sh`.

Prioridad sugerida:

1. `vm_create_users.sh`
2. `vm_change_hostname.sh`
3. `vm_fix_netplan_dhcp.sh`
4. `install_pip_cache.sh`
5. `resize_vm.sh`
6. `vm_watchdog.sh`
7. `vm_to_template.sh`
8. `vm_enable_external_vnc.sh`

Para VNC runtime password y algunos movimientos de disco puede hacer falta un
fallback SSH al nodo si tu versión de Proxmox no expone la operación exacta por API.
