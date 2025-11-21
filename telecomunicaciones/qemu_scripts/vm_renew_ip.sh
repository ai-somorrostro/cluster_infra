#!/bin/bash

# vm_renew_ip.sh - Renueva IP DHCP en interfaz ens18

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

INTERFACE="ens18"

echo "=========================================="
echo "Nodo: $NODE"
echo "VMs: ${VMIDS[*]}"
echo "Interfaz: $INTERFACE"
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

    # 1. Liberar IP actual
    echo -e "${YELLOW}[*]${NC} Liberando IP en $INTERFACE..."
    if run_cmd "dhclient" "-r" "$INTERFACE"; then
        echo -e "${GREEN}[✓]${NC} IP liberada"
    else
        echo -e "${YELLOW}[!]${NC} No se pudo liberar IP (puede ser normal)"
    fi
    
    sleep 2

    # 2. Solicitar nueva IP
    echo -e "${YELLOW}[*]${NC} Solicitando nueva IP en $INTERFACE..."
    if run_cmd "dhclient" "-v" "$INTERFACE"; then
        echo -e "${GREEN}[✓]${NC} Nueva IP asignada"
    else
        echo -e "${RED}[✗]${NC} Error al solicitar IP"
        continue
    fi
    
    sleep 3

    # 3. Mostrar nueva IP
    echo -e "${YELLOW}[*]${NC} Obteniendo IP actual de $INTERFACE..."
    GET_IP_CMD="ip -4 addr show $INTERFACE | grep inet | awk '{print \$2}' | cut -d/ -f1"
    
    # Ejecutar y capturar (intentamos leer el exec-status)
    OUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sh" --command "-c" --command "$GET_IP_CMD" --output-format json 2>/dev/null)
    PID=$(echo "$OUT" | grep -oP '"pid":\K[0-9]+')
    
    if [ -n "$PID" ]; then
        sleep 2
        IP_DATA=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $PID --output-format json 2>/dev/null || echo "")
        NEW_IP=$(echo "$IP_DATA" | grep -oP '"out-data":"[^"]*\\n' | grep -oP '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        
        if [ -n "$NEW_IP" ]; then
            echo -e "${GREEN}[✓]${NC} Nueva IP: $NEW_IP"
        else
            echo -e "${YELLOW}[?]${NC} No se pudo determinar la IP"
        fi
    fi
done

echo -e "\n=========================================="
echo "Proceso completado"
echo "=========================================="
