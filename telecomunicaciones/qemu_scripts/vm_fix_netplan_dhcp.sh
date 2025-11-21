#!/bin/bash

# vm_fix_netplan_dhcp.sh - Configura netplan para usar MAC como identificador DHCP

set -e

if [ $# -lt 2 ]; then
    echo "Uso: $0 <nodo> <vmid1> [vmid2] ..."
    echo "Ejemplo: $0 pve-node-3 127 128 129"
    exit 1
fi

NODE=$1
shift
VMIDS=("$@")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"

echo "=========================================="
echo "Nodo: $NODE"
echo "VMs: ${VMIDS[*]}"
echo "Fix: Agregar dhcp-identifier: mac a netplan"
echo "=========================================="

# --- Funciones Helper ---
wait_for_pid() {
    local pid=$1
    local timeout=$2
    local count=0
    while [ $count -lt $timeout ]; do
        sleep 1
        local status=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $pid --output-format json 2>/dev/null || echo "")
        if echo "$status" | grep -q '"exited"'; then
            echo "$status"
            return 0
        fi
        echo -n "."
        count=$((count+1))
    done
    echo ""
    return 1
}

run_cmd() {
    local cmd_arr=("$@")
    local pvesh_args=""
    for arg in "${cmd_arr[@]}"; do
        local escaped_arg=$(echo "$arg" | sed 's/"/\\"/g')
        pvesh_args="$pvesh_args --command \"$escaped_arg\""
    done
    local out=$(eval pvesh create /nodes/$NODE/qemu/$VMID/agent/exec $pvesh_args --output-format json 2>/dev/null)
    local pid=$(echo "$out" | grep -oP '"pid":\K[0-9]+')
    if [ -z "$pid" ]; then return 1; fi
    local res=$(wait_for_pid $pid 60)
    local exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
    return $exitcode
}

# --- Loop Principal ---

for VMID in "${VMIDS[@]}"; do
    echo -e "\n${YELLOW}[*]${NC} Procesando VM $VMID..."

    # Verificar estado
    VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)
    if echo "$VM_STATUS" | grep -q '"status":"running"' && echo "$VM_STATUS" | grep -q '"agent":1'; then
        echo -e "${GREEN}[✓]${NC} VM corriendo y agente activo"
    else
        echo -e "${RED}[✗]${NC} VM no disponible o agente inactivo"
        continue
    fi

    # 1. Backup
    echo -e "${YELLOW}[*]${NC} Haciendo backup..."
    run_cmd "cp" "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"

    # 2. Verificar si ya existe
    if run_cmd "grep" "-q" "dhcp-identifier" "$NETPLAN_FILE"; then
        echo -e "${YELLOW}[!]${NC} dhcp-identifier ya existe, omitiendo"
        continue
    fi

    # 3. Escribir netplan línea por línea
    echo -e "${YELLOW}[*]${NC} Escribiendo configuración..."
    
    run_cmd "sh" "-c" "echo 'network:' > $NETPLAN_FILE"
    run_cmd "sh" "-c" "echo '  version: 2' >> $NETPLAN_FILE"
    run_cmd "sh" "-c" "echo '  ethernets:' >> $NETPLAN_FILE"
    run_cmd "sh" "-c" "echo '    ens18:' >> $NETPLAN_FILE"
    run_cmd "sh" "-c" "echo '      dhcp4: true' >> $NETPLAN_FILE"
    run_cmd "sh" "-c" "echo '      dhcp-identifier: mac' >> $NETPLAN_FILE"
    
    echo -e "${GREEN}[✓]${NC} Configuración escrita"

    # 4. Aplicar netplan
    echo -e "${YELLOW}[*]${NC} Aplicando netplan..."
    if run_cmd "netplan" "apply"; then
        echo -e "${GREEN}[✓]${NC} Netplan aplicado"
    else
        echo -e "${RED}[✗]${NC} Error, restaurando backup..."
        run_cmd "cp" "${NETPLAN_FILE}.bak" "$NETPLAN_FILE"
        continue
    fi

    # 5. Reiniciar interfaz
    echo -e "${YELLOW}[*]${NC} Reiniciando ens18..."
    run_cmd "sh" "-c" "ip link set ens18 down && sleep 2 && ip link set ens18 up"

    sleep 5

    # 6. Mostrar IP
    NEW_IPS=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/network-get-interfaces --output-format json 2>/dev/null | grep -oP '"ip-address":"\K[0-9.]+' | grep -v "127.0.0.1" | grep -v "^172.17" || echo "")
    
    if [ -n "$NEW_IPS" ]; then
        echo -e "${GREEN}[✓]${NC} IPs: $NEW_IPS"
    fi
done

echo -e "\n=========================================="
echo "Completado"
echo "=========================================="
