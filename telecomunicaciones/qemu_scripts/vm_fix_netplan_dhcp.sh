#!/bin/bash

# vm_fix_netplan_dhcp.sh - Configura netplan para usar MAC como identificador DHCP

set -e

if [ $# -lt 2 ]; then
    echo "Uso: $0 <nodo> <vmid1> [vmid2] ..."
    exit 1
fi

NODE=$1
shift
VMIDS=("$@")

NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"

for VMID in "${VMIDS[@]}"; do
    echo "=== VM $VMID ==="
    
    # Backup
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "cp" --command "$NETPLAN_FILE" --command "${NETPLAN_FILE}.bak" >/dev/null 2>&1
    
    # Modificar con Python (comando que SÍ funcionó en VM 128)
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec \
      --command "python3" \
      --command "-c" \
      --command "from pathlib import Path; p=Path('/etc/netplan/50-cloud-init.yaml'); t=p.read_text(); t=t.replace('      dhcp4: true\n', '      dhcp4: true\n      dhcp-identifier: mac\n', 1); p.write_text(t)" \
      >/dev/null 2>&1
    
    sleep 2
    
    # Aplicar
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "netplan" --command "apply" >/dev/null 2>&1
    
    sleep 2
    
    # Reiniciar interfaz
    pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sh" --command "-c" --command "ip link set ens18 down && sleep 2 && ip link set ens18 up" >/dev/null 2>&1
    
    sleep 5
    
    # Mostrar IP
    pvesh get /nodes/$NODE/qemu/$VMID/agent/network-get-interfaces --output-format json 2>/dev/null | grep -oP '"ip-address":"\K[0-9.]+' | grep -v "127.0.0.1" | grep -v "^172.17"
    
    echo "OK"
done
