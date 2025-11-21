#!/bin/bash

# vm_debug_cmd.sh - Ejecuta un comando en una VM y muestra toda la info

if [ $# -lt 3 ]; then
    echo "Uso: $0 <nodo> <vmid> <comando> [args...]"
    echo "Ejemplo: $0 pve-node-3 127 ip a"
    echo "Ejemplo: $0 pve-node-3 127 dhclient -v ens18"
    exit 1
fi

NODE=$1
VMID=$2
shift 2
CMD=("$@")

echo "=========================================="
echo "Nodo: $NODE"
echo "VMID: $VMID"
echo "Comando: ${CMD[*]}"
echo "=========================================="

# Construir comando pvesh
PVESH_ARGS=""
for arg in "${CMD[@]}"; do
    escaped=$(echo "$arg" | sed 's/"/\\"/g')
    PVESH_ARGS="$PVESH_ARGS --command \"$escaped\""
done

echo -e "\n[*] Ejecutando comando..."
OUT=$(eval pvesh create /nodes/$NODE/qemu/$VMID/agent/exec $PVESH_ARGS --output-format json 2>&1)
echo "Raw output:"
echo "$OUT"

PID=$(echo "$OUT" | grep -oP '"pid":\K[0-9]+' || echo "")

if [ -z "$PID" ]; then
    echo -e "\n[ERROR] No se obtuvo PID"
    exit 1
fi

echo -e "\n[*] PID: $PID"
echo "[*] Esperando resultado..."

# Esperar
for i in {1..30}; do
    sleep 1
    STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $PID --output-format json 2>/dev/null || echo "")
    
    if echo "$STATUS" | grep -q '"exited"'; then
        echo -e "\n[*] Comando finalizado"
        echo "Status completo:"
        echo "$STATUS" | jq . 2>/dev/null || echo "$STATUS"
        
        EXITCODE=$(echo "$STATUS" | grep -oP '"exitcode":\K[0-9]+' || echo "?")
        echo -e "\n=========================================="
        echo "Exit code: $EXITCODE"
        echo "=========================================="
        exit $EXITCODE
    fi
    echo -n "."
done

echo -e "\n[TIMEOUT] Comando no finalizó en 30s"
exit 1

