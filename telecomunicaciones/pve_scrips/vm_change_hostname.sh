#!/bin/bash

# vm_change_hostname.sh - Cambia el hostname de una VM

set -e

if [ $# -ne 2 ]; then
    echo "Uso: $0 <vmid> <nuevo_hostname>"
    echo "Ejemplo: $0 127 webserver01"
    exit 1
fi

VMID=$1
NEW_HOSTNAME=$2

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

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
    local res=$(wait_for_pid $pid 30)
    local exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
    return $exitcode
}

echo -e "\n${YELLOW}=========================================="
echo "Detectando ubicación de la VM $VMID..."

# Detectar nodo y nombre de la VM
VM_INFO=$(pvesh get /cluster/resources --type vm --output-format json | \
  python3 -c "import sys, json; \
  vms = json.load(sys.stdin); \
  vm = next((i for i in vms if i.get('vmid') == $VMID), None); \
  print(f\"{vm.get('node', 'N/A')}|{vm.get('name', 'N/A')}\") if vm else print('N/A|N/A')")

NODE=$(echo "$VM_INFO" | cut -d'|' -f1)
VM_NAME=$(echo "$VM_INFO" | cut -d'|' -f2)

if [ "$NODE" = "N/A" ] || [ -z "$NODE" ]; then
  echo -e "${RED}[✗]${NC} No se encuentra la VM $VMID en ningun nodo del cluster."
  exit 1
fi

echo "Nodo: $NODE | Nombre: $VM_NAME | VMID: $VMID"
echo -e "==========================================${NC}"

# Verificar estado
echo -n "Verificando estado de la VM... "
VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)
if ! echo "$VM_STATUS" | grep -q '"status":"running"' || ! echo "$VM_STATUS" | grep -q '"agent":1'; then
    echo -e "${RED}[✗]${NC}"
    echo -e "${RED}Error: VM no está en ejecución o el agente no está activo${NC}"
    exit 1
fi
echo -e "${GREEN}[OK]${NC}"

# Obtener hostname actual
echo -n "Hostname actual... "
CURRENT_HOSTNAME=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "hostname" --output-format json 2>/dev/null | grep -oP '"pid":\K[0-9]+')
sleep 1
HOSTNAME_OUTPUT=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $CURRENT_HOSTNAME --output-format json 2>/dev/null | grep -oP '"out-data":"[^"]+' | cut -d'"' -f3 | base64 -d 2>/dev/null || echo "desconocido")
echo -e "${YELLOW}$HOSTNAME_OUTPUT${NC}"

if [ "$HOSTNAME_OUTPUT" = "$NEW_HOSTNAME" ]; then
    echo -e "${YELLOW}[!]${NC} El hostname ya es '$NEW_HOSTNAME', no se requieren cambios"
    exit 0
fi

echo -e "\n${YELLOW}Cambiando hostname a: $NEW_HOSTNAME${NC}\n"

# Cambiar hostname usando hostnamectl
echo -n "Aplicando nuevo hostname (hostnamectl)... "
if run_cmd "hostnamectl" "set-hostname" "$NEW_HOSTNAME"; then
    echo -e "${GREEN}[OK]${NC}"
else
    echo -e "${RED}[ERROR]${NC}"
    exit 1
fi

# Backup /etc/hostname
echo -n "Backup /etc/hostname... "
run_cmd "cp" "/etc/hostname" "/etc/hostname.bak" && echo -e "${GREEN}[OK]${NC}" || echo -e "${YELLOW}[WARN]${NC}"

# Actualizar /etc/hostname (por si hostnamectl no lo hizo)
echo -n "Actualizando /etc/hostname... "
if run_cmd "sh" "-c" "echo '$NEW_HOSTNAME' > /etc/hostname"; then
    echo -e "${GREEN}[OK]${NC}"
else
    echo -e "${RED}[ERROR]${NC}"
fi

# Backup /etc/hosts
echo -n "Backup /etc/hosts... "
run_cmd "cp" "/etc/hosts" "/etc/hosts.bak" && echo -e "${GREEN}[OK]${NC}" || echo -e "${YELLOW}[WARN]${NC}"

# Actualizar /etc/hosts
echo -n "Actualizando /etc/hosts... "
if run_cmd "sh" "-c" "sed -i 's/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/' /etc/hosts && grep -q '127.0.1.1' /etc/hosts || echo '127.0.1.1\t$NEW_HOSTNAME' >> /etc/hosts"; then
    echo -e "${GREEN}[OK]${NC}"
else
    echo -e "${YELLOW}[WARN]${NC}"
fi

# Verificar el cambio
echo -n "Verificando hostname nuevo... "
VERIFY_HOSTNAME=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "hostname" --output-format json 2>/dev/null | grep -oP '"pid":\K[0-9]+')
sleep 1
NEW_HOSTNAME_OUTPUT=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $VERIFY_HOSTNAME --output-format json 2>/dev/null | grep -oP '"out-data":"[^"]+' | cut -d'"' -f3 | base64 -d 2>/dev/null || echo "error")

if [ "$NEW_HOSTNAME_OUTPUT" = "$NEW_HOSTNAME" ]; then
    echo -e "${GREEN}[OK] - $NEW_HOSTNAME_OUTPUT${NC}"
else
    echo -e "${YELLOW}[WARN] - $NEW_HOSTNAME_OUTPUT${NC}"
    echo -e "${YELLOW}[!]${NC} Puede ser necesario reiniciar la VM para que los cambios tengan efecto completo"
fi

echo -e "\n${GREEN}=========================================="
echo "Completado"
echo "Hostname cambiado de '$HOSTNAME_OUTPUT' a '$NEW_HOSTNAME'"
echo "==========================================${NC}"
