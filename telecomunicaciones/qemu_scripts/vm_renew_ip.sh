#!/bin/bash

# vm_renew_ip.sh - Fuerza renovación de IP en VMs clonadas

set -e

if [ $# -lt 2 ]; then
    echo "Uso: $0 <nodo> <vmid1> [vmid2] ..."
    echo "Ejemplo: $0 pve-node-3 100 101"
    exit 1
fi

NODE=$1
shift
VMIDS=("$@")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "Nodo: $NODE"
echo "VMs: ${VMIDS[*]}"
echo "=========================================="

# --- Funciones Helper (reutilizadas del anterior) ---
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

    # 1. Regenerar Machine ID (crítico para clones)
    echo -e "${YELLOW}[*]${NC} Regenerando Machine ID..."
    REGEN_CMD="rm -f /etc/machine-id /var/lib/dbus/machine-id && dbus-uuidgen --ensure && systemd-machine-id-setup"
    run_cmd "sh" "-c" "$REGEN_CMD"

    # 2. Limpiar leases DHCP antiguos
    echo -e "${YELLOW}[*]${NC} Limpiando leases DHCP..."
    CLEAN_CMD="rm -f /var/lib/dhcp/*"
    run_cmd "sh" "-c" "$CLEAN_CMD"

    # 3. Reiniciar Networking para pedir nueva IP
    echo -e "${YELLOW}[*]${NC} Solicitando nueva IP..."
    # Intentamos netplan apply primero (Ubuntu moderno), fallback a ifdown/up
    if run_cmd "netplan" "apply"; then
        echo -e "${GREEN}[✓]${NC} Netplan aplicado"
    else
        # Fallback genérico
        run_cmd "systemctl" "restart" "systemd-networkd"
    fi
    
    # Esperar un poco
    sleep 5

    # 4. Mostrar nueva IP
    echo -e "${YELLOW}[*]${NC} Obteniendo IP actual..."
    IPS=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/network-get-interfaces --output-format json 2>/dev/null | grep -oP '"ip-address":"\K[0-9.]+' | grep -v "127.0.0.1")
    
    if [ -n "$IPS" ]; then
        echo -e "${GREEN}[✓]${NC} Nuevas IPs: $IPS"
    else
        echo -e "${RED}[?]${NC} No se detectaron IPs (puede tardar unos segundos)"
    fi
done

echo -e "\n=========================================="
echo "Proceso completado"
echo "=========================================="
