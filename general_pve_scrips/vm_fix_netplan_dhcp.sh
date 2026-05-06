#!/bin/bash

# vm_fix_netplan_dhcp.sh - Configura netplan para usar MAC como identificador DHCP

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/pve-load-env.sh"

if [ $# -lt 2 ]; then
    echo "Uso: $0 <nodo> <vmid1> [vmid2] ..."
    exit 1
fi

NODE=$1
shift
VMIDS=("$@")

NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

for VMID in "${VMIDS[@]}"; do
    echo -e "\n${YELLOW}=== VM $VMID ===${NC}"
    
    # Backup
    echo -n "Backup... "
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "cp" --command "$NETPLAN_FILE" --command "${NETPLAN_FILE}.bak" >/dev/null 2>&1 || true
    echo -e "${GREEN}OK${NC}"
    
    # Verificar si el fichero tiene dhcp4
    echo -n "Verificando fichero... "
    CHECK=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "grep" --command "-c" --command "dhcp4" --command "$NETPLAN_FILE" --output-format json 2>/dev/null | grep -oP '"pid":\K[0-9]+')
    sleep 1
    HAS_DHCP4=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $CHECK --output-format json 2>/dev/null | grep -oP '"exitcode":\K[0-9]+')
    
    if [ "$HAS_DHCP4" != "0" ]; then
        # Fichero vacío o sin dhcp4, escribir plantilla completa
        echo "vacío, escribiendo plantilla... "
        pvesh create /nodes/$NODE/qemu/$VMID/agent/exec \
          --command "python3" \
          --command "-c" \
          --command "from pathlib import Path; Path('/etc/netplan/50-cloud-init.yaml').write_text('network:\n  version: 2\n  ethernets:\n    ens18:\n      dhcp4: true\n      dhcp-identifier: mac\n')" \
          >/dev/null 2>&1
    else
        # Fichero con dhcp4, añadir dhcp-identifier
        echo "modificando... "
        pvesh create /nodes/$NODE/qemu/$VMID/agent/exec \
          --command "python3" \
          --command "-c" \
          --command "from pathlib import Path; p=Path('/etc/netplan/50-cloud-init.yaml'); t=p.read_text(); t=t.replace('      dhcp4: true\n', '      dhcp4: true\n      dhcp-identifier: mac\n', 1); p.write_text(t)" \
          >/dev/null 2>&1
    fi
    echo -e "${GREEN}OK${NC}"
    
    sleep 2
    
    # Aplicar
    echo -n "Aplicando netplan... "
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "netplan" --command "apply" >/dev/null 2>&1
    echo -e "${GREEN}OK${NC}"
    
    sleep 2
    
    # Reiniciar interfaz
    echo -n "Reiniciando ens18... "
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sh" --command "-c" --command "ip link set ens18 down && sleep 2 && ip link set ens18 up" >/dev/null 2>&1
    echo -e "${GREEN}OK${NC}"
    
    sleep 5
    
    # Mostrar IP
    echo -n "IP: "
    pvesh get /nodes/$NODE/qemu/$VMID/agent/network-get-interfaces --output-format json 2>/dev/null | grep -oP '"ip-address":"\K[0-9.]+' | grep -v "127.0.0.1" | grep -v "^172.17"
done

echo -e "\n${GREEN}Completado${NC}"
