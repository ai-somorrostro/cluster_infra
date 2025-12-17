#!/bin/bash

# diagnose_network.sh - Diagnostica problemas de red en una VM

if [ $# -lt 1 ]; then
    echo "Uso: $0 <vmid>"
    echo "Ejemplo: $0 112"
    exit 1
fi

VMID=$1

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Detectar nodo
VM_INFO=$(pvesh get /cluster/resources --type vm --output-format json | \
  python3 -c "import sys, json; \
  vms = json.load(sys.stdin); \
  vm = next((i for i in vms if i.get('vmid') == $VMID), None); \
  print(f\"{vm.get('node', 'N/A')}|{vm.get('name', 'N/A')}\") if vm else print('N/A|N/A')")

NODE=$(echo "$VM_INFO" | cut -d'|' -f1)
VM_NAME=$(echo "$VM_INFO" | cut -d'|' -f2)

if [ "$NODE" = "N/A" ]; then
    echo -e "${RED}[✗]${NC} VM $VMID no encontrada"
    exit 1
fi

echo -e "${YELLOW}VM: $VM_NAME (ID: $VMID) en nodo $NODE${NC}\n"

# Función helper
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
        count=$((count+1))
    done
    return 1
}

run_cmd_output() {
    local cmd_arr=("$@")
    local pvesh_args=""
    for arg in "${cmd_arr[@]}"; do
        local escaped_arg=$(echo "$arg" | sed 's/"/\\"/g')
        pvesh_args="$pvesh_args --command \"$escaped_arg\""
    done
    local out=$(eval pvesh create /nodes/$NODE/qemu/$VMID/agent/exec $pvesh_args --output-format json 2>/dev/null)
    local pid=$(echo "$out" | grep -oP '"pid":\K[0-9]+')
    if [ -z "$pid" ]; then
        echo "Error ejecutando comando"
        return 1
    fi
    local res=$(wait_for_pid $pid 30)
    local exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
    local outdata=$(echo "$res" | grep -oP '"out-data":"?\K[^"]*' | base64 -d 2>/dev/null || echo "")
    echo "$outdata"
    return $exitcode
}

echo -e "${YELLOW}[1] Interfaces de red:${NC}"
run_cmd_output "ip" "addr" "show"

echo -e "\n${YELLOW}[2] Rutas:${NC}"
run_cmd_output "ip" "route" "show"

echo -e "\n${YELLOW}[3] DNS (/etc/resolv.conf):${NC}"
run_cmd_output "cat" "/etc/resolv.conf"

echo -e "\n${YELLOW}[4] Ping a gateway (si existe):${NC}"
GATEWAY=$(run_cmd_output "ip" "route" "show" | grep "^default" | awk '{print $3}' | head -1)
if [ -n "$GATEWAY" ]; then
    echo "Gateway: $GATEWAY"
    run_cmd_output "ping" "-c" "2" "$GATEWAY"
else
    echo "No se encontró gateway por defecto"
fi

echo -e "\n${YELLOW}[5] Ping a 8.8.8.8:${NC}"
run_cmd_output "ping" "-c" "2" "8.8.8.8"

echo -e "\n${YELLOW}[6] Configuración de red en Proxmox:${NC}"
pvesh get /nodes/$NODE/qemu/$VMID/config --output-format json | grep -E '"net[0-9]"' || echo "No hay interfaces configuradas"
