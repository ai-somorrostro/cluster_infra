#!/bin/bash

# vm_fix_cloned_ip.sh - Soluciona IPs duplicadas en VMs clonadas regenerando machine-id y netplan

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

echo "=========================================="
echo "Nodo: $NODE"
echo "VMs: ${VMIDS[*]}"
echo "Fix: Regenerar machine-id y netplan"
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

    # 1. Regenerar machine-id (crítico para clones)
    echo -e "${YELLOW}[*]${NC} Regenerando machine-id..."
    REGEN_CMD="rm -f /etc/machine-id /var/lib/dbus/machine-id"
    if run_cmd "sh" "-c" "$REGEN_CMD"; then
        echo -e "${GREEN}[✓]${NC} Machine-id eliminado"
    else
        echo -e "${RED}[✗]${NC} Error al eliminar machine-id"
        continue
    fi
    
    # Crear nuevo machine-id
    if run_cmd "systemd-machine-id-setup"; then
        echo -e "${GREEN}[✓]${NC} Nuevo machine-id generado"
    else
        echo -e "${RED}[✗]${NC} Error al generar machine-id"
        continue
    fi

    # 2. Limpiar leases y cache de netplan/networkd
    echo -e "${YELLOW}[*]${NC} Limpiando leases DHCP..."
    CLEAN_CMD="rm -f /var/lib/dhcp/* /var/lib/NetworkManager/* /run/systemd/netif/leases/*"
    run_cmd "sh" "-c" "$CLEAN_CMD"
    
    # 3. Regenerar netif persistent state
    echo -e "${YELLOW}[*]${NC} Limpiando estado persistente de red..."
    CLEAN_NETIF="rm -rf /var/lib/systemd/network/*"
    run_cmd "sh" "-c" "$CLEAN_NETIF"

    # 4. Reiniciar servicios de red
    echo -e "${YELLOW}[*]${NC} Reiniciando servicios de red..."
    
    # Probar netplan primero
    if run_cmd "netplan" "apply"; then
        echo -e "${GREEN}[✓]${NC} Netplan aplicado"
    else
        # Fallback a systemd-networkd
        if run_cmd "systemctl" "restart" "systemd-networkd"; then
            echo -e "${GREEN}[✓]${NC} systemd-networkd reiniciado"
        else
            echo -e "${YELLOW}[!]${NC} No se pudo reiniciar red automáticamente"
        fi
    fi
    
    # Esperar a que obtenga nueva IP
    sleep 5

    # 5. Mostrar nueva IP
    echo -e "${YELLOW}[*]${NC} Obteniendo nueva IP..."
    
    # Intentar obtener IPs del agent
    NEW_IPS=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/network-get-interfaces --output-format json 2>/dev/null | grep -oP '"ip-address":"\K[0-9.]+' | grep -v "127.0.0.1" | grep -v "^172.17" || echo "")
    
    if [ -n "$NEW_IPS" ]; then
        echo -e "${GREEN}[✓]${NC} Nuevas IPs detectadas:"
        echo "$NEW_IPS" | while read ip; do
            echo "  - $ip"
        done
    else
        echo -e "${YELLOW}[?]${NC} No se detectaron IPs nuevas aún (puede tardar unos segundos más)"
    fi
done

echo -e "\n=========================================="
echo "Proceso completado"
echo "Nota: Si las IPs no cambiaron, espera 1 minuto y verifica manualmente"
echo "=========================================="

