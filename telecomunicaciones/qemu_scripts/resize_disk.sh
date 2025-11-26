#!/bin/bash

# resize_disk.sh - Resize LVM disk of VMs

set -e

if [ $# -lt 3 ]; then
    echo "Uso: $0 <nodo> <vmid1> [vmid2] ... <cantidad>"
    echo "Ejemplo: $0 pve 100 101 102 +10G"
    echo ""
    echo "La cantidad debe ser en formato: +10G, +500M, etc."
    exit 1
fi

NODE=$1
shift
# Último argumento es la cantidad
AMOUNT="${@: -1}"
VMIDS=("${@:1:$(($#-1))}")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
    
    if [ -z "$pid" ]; then
        return 1
    fi
    
    local res=$(wait_for_pid $pid 60)
    local exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
    return $exitcode
}

get_cmd_output() {
    local cmd_arr=("$@")
    local pvesh_args=""
    for arg in "${cmd_arr[@]}"; do
        local escaped_arg=$(echo "$arg" | sed 's/"/\\"/g')
        pvesh_args="$pvesh_args --command \"$escaped_arg\""
    done
    
    local out=$(eval pvesh create /nodes/$NODE/qemu/$VMID/agent/exec $pvesh_args --output-format json 2>/dev/null)
    local pid=$(echo "$out" | grep -oP '"pid":\K[0-9]+')
    
    if [ -z "$pid" ]; then
        echo ""
        return 1
    fi
    
    local res=$(wait_for_pid $pid 30)
    local out_data=$(echo "$res" | grep -oP '"out-data":"\K[^"]+' || echo "")
    if [ -n "$out_data" ]; then
        echo -n "$out_data" | base64 -d 2>/dev/null | tr -d '\r\n' | sed 's/[[:space:]]*$//'
    fi
}

wait_for_vm_status() {
    local target_status=$1
    local timeout=$2
    local count=0
    
    while [ $count -lt $timeout ]; do
        local status=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)
        local current=$(echo "$status" | grep -oP '"status":"\K[^"]+')
        if [ "$current" == "$target_status" ]; then
            return 0
        fi
        sleep 2
        count=$((count+2))
        echo -n "."
    done
    echo ""
    return 1
}

get_disk_device() {
    # Obtener el primer disco del sistema (normalmente scsi0, virtio0, sata0, etc.)
    local config=$(pvesh get /nodes/$NODE/qemu/$VMID/config --output-format json 2>/dev/null)
    # Buscar el primer disco que no sea de instalación
    local disk=$(echo "$config" | grep -oP '(scsi|virtio|sata|ide)0:' | head -1 | cut -d: -f1)
    if [ -z "$disk" ]; then
        # Por defecto usar scsi0
        echo "scsi0"
    else
        echo "$disk"
    fi
}

# --- Loop por VM ---

for VMID in "${VMIDS[@]}"; do
    echo -e "\n${YELLOW}=========================================="
    echo "VM $VMID - Aumentar disco $AMOUNT"
    echo -e "==========================================${NC}"
    
    # Verificar VM existe
    VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)
    if [ -z "$VM_STATUS" ]; then
        echo -e "${RED}[✗]${NC} VM $VMID no existe en nodo $NODE"
        continue
    fi
    
    # 1. Apagar VM si está corriendo
    CURRENT_STATUS=$(echo "$VM_STATUS" | grep -oP '"status":"\K[^"]+')
    if [ "$CURRENT_STATUS" == "running" ]; then
        echo -e "${YELLOW}[*]${NC} VM está corriendo, apagando..."
        pvesh create /nodes/$NODE/qemu/$VMID/status/shutdown >/dev/null 2>&1
        if wait_for_vm_status "stopped" 30; then
            echo -e "${GREEN}[✓]${NC} VM apagada"
        else
            echo -e "${YELLOW}[!]${NC} Timeout esperando apagado, intentando forzar..."
            pvesh create /nodes/$NODE/qemu/$VMID/status/stop >/dev/null 2>&1
            sleep 5
        fi
    else
        echo -e "${GREEN}[✓]${NC} VM ya está apagada"
    fi
    
    # 2. Obtener dispositivo de disco
    DISK_DEV=$(get_disk_device)
    echo -e "${YELLOW}[*]${NC} Disco detectado: $DISK_DEV"
    
    # 3. Redimensionar en Proxmox
    echo -e "${YELLOW}[*]${NC} Redimensionando disco en Proxmox..."
    if qm resize $VMID $DISK_DEV $AMOUNT 2>/dev/null || pvesh create /nodes/$NODE/qemu/$VMID/resize --disk $DISK_DEV --size $AMOUNT >/dev/null 2>&1; then
        echo -e "${GREEN}[✓]${NC} Disco redimensionado en Proxmox"
    else
        echo -e "${RED}[✗]${NC} Error redimensionando disco en Proxmox"
        continue
    fi
    
    # 4. Iniciar VM
    echo -e "${YELLOW}[*]${NC} Iniciando VM..."
    pvesh create /nodes/$NODE/qemu/$VMID/status/start >/dev/null 2>&1
    if wait_for_vm_status "running" 60; then
        echo -e "${GREEN}[✓]${NC} VM iniciada"
    else
        echo -e "${RED}[✗]${NC} Error iniciando VM"
        continue
    fi
    
    # Esperar a que el agente esté disponible
    sleep 5
    AGENT_READY=0
    for i in {1..10}; do
        VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)
        AGENT_ENABLED=$(echo "$VM_STATUS" | grep -oP '"agent":\K[0-9]+' || echo "0")
        if [ "$AGENT_ENABLED" == "1" ]; then
            AGENT_READY=1
            break
        fi
        sleep 2
    done
    
    if [ $AGENT_READY -eq 0 ]; then
        echo -e "${RED}[✗]${NC} qemu-guest-agent no disponible"
        continue
    fi
    
    # 5. Aplicar redimensionado dentro de la VM
    echo -e "${YELLOW}[*]${NC} Aplicando redimensionado LVM en la VM..."
    
    # Detectar dispositivo de bloque principal
    echo -n "  • Detectando dispositivo... "
    MAIN_DEVICE=$(get_cmd_output "sh" "-c" "lsblk -ndo NAME,TYPE | grep disk | head -1 | awk '{print \$1}'")
    if [ -z "$MAIN_DEVICE" ]; then
        MAIN_DEVICE="sda"
    fi
    echo "/dev/$MAIN_DEVICE"
    
    # Rescan del dispositivo
    echo -n "  • Rescanning dispositivo... "
    if run_cmd "sh" "-c" "echo 1 > /sys/class/block/${MAIN_DEVICE}/device/rescan 2>/dev/null || partprobe /dev/${MAIN_DEVICE}"; then
        echo -e "${GREEN}[✓]${NC}"
    else
        echo -e "${YELLOW}[!]${NC} (continuando...)"
    fi
    
    sleep 2
    
    # Detectar partición o usar disco directamente
    echo -n "  • Detectando partición... "
    PARTITION=$(get_cmd_output "sh" "-c" "lsblk -ndo NAME,TYPE /dev/${MAIN_DEVICE} | grep part | head -1 | awk '{print \$1}'")
    HAS_PARTITIONS=1
    
    if [ -z "$PARTITION" ]; then
        # No hay particiones, LVM directamente en el disco
        PARTITION="$MAIN_DEVICE"
        HAS_PARTITIONS=0
        echo "LVM directamente en /dev/$MAIN_DEVICE (sin particiones)"
    else
        echo "/dev/$PARTITION"
    fi
    
    # Expandir partición solo si hay particiones
    if [ $HAS_PARTITIONS -eq 1 ]; then
        echo -n "  • Expandiendo partición... "
        PART_NUM="${PARTITION#${MAIN_DEVICE}}"
        if run_cmd "growpart" "/dev/${MAIN_DEVICE}" "$PART_NUM" 2>/dev/null; then
            echo -e "${GREEN}[✓]${NC}"
        elif run_cmd "sh" "-c" "parted /dev/${MAIN_DEVICE} resizepart ${PART_NUM} 100%"; then
            echo -e "${GREEN}[✓]${NC}"
        else
            echo -e "${YELLOW}[!]${NC} (puede que no sea necesario o ya expandida)"
        fi
        sleep 2
    fi
    
    # Rescan PV
    echo -n "  • Rescanning PV... "
    if run_cmd "pvresize" "/dev/$PARTITION"; then
        echo -e "${GREEN}[✓]${NC}"
    else
        echo -e "${YELLOW}[!]${NC} Intentando método alternativo..."
        if [ $HAS_PARTITIONS -eq 1 ]; then
            run_cmd "partprobe" "/dev/$PARTITION" || true
        fi
        sleep 2
        if ! run_cmd "pvresize" "/dev/$PARTITION"; then
            echo -e "${RED}[✗]${NC} Error en pvresize"
            continue
        fi
    fi
    
    # Obtener VG y LV
    echo -n "  • Detectando VG y LV... "
    VG_NAME=$(get_cmd_output "sh" "-c" "vgs --noheadings -o vg_name | head -1 | tr -d ' '")
    LV_INFO=$(get_cmd_output "sh" "-c" "lvs --noheadings -o vg_name,lv_name | head -1")
    
    if [ -z "$VG_NAME" ] || [ -z "$LV_INFO" ]; then
        echo -e "${RED}[✗]${NC} No se pudo detectar VG/LV"
        continue
    fi
    
    LV_NAME=$(echo "$LV_INFO" | awk '{print $2}')
    echo "$VG_NAME/$LV_NAME"
    
    # Expandir LV
    echo -n "  • Expandiendo LV... "
    if run_cmd "lvextend" "-l" "+100%FREE" "$VG_NAME/$LV_NAME"; then
        echo -e "${GREEN}[✓]${NC}"
    else
        echo -e "${RED}[✗]${NC} Error expandiendo LV"
        continue
    fi
    
    # Detectar filesystem y redimensionar
    echo -n "  • Detectando filesystem... "
    FS_TYPE=$(get_cmd_output "blkid" "/dev/$VG_NAME/$LV_NAME" "-o" "value" "-s" "TYPE")
    
    if [ -z "$FS_TYPE" ]; then
        echo -e "${RED}[✗]${NC} No se pudo detectar filesystem"
        continue
    fi
    echo "$FS_TYPE"
    
    # Redimensionar filesystem
    echo -n "  • Redimensionando filesystem... "
    if [ "$FS_TYPE" == "xfs" ]; then
        if run_cmd "xfs_growfs" "/" 2>/dev/null || run_cmd "xfs_growfs" "/dev/$VG_NAME/$LV_NAME"; then
            echo -e "${GREEN}[✓]${NC}"
        else
            echo -e "${RED}[✗]${NC}"
            continue
        fi
    elif [ "$FS_TYPE" == "ext4" ] || [ "$FS_TYPE" == "ext3" ] || [ "$FS_TYPE" == "ext2" ]; then
        if run_cmd "resize2fs" "/dev/$VG_NAME/$LV_NAME"; then
            echo -e "${GREEN}[✓]${NC}"
        else
            echo -e "${RED}[✗]${NC}"
            continue
        fi
    else
        echo -e "${YELLOW}[!]${NC} Filesystem $FS_TYPE no soportado automáticamente"
    fi
    
    # Verificar resultado
    echo -n "  • Verificando espacio... "
    DF_OUT=$(get_cmd_output "sh" "-c" "df -h / | tail -1 | awk '{print \$2, \$3, \$4}'")
    echo "$DF_OUT"
    
    echo -e "${GREEN}[✓]${NC} Disco redimensionado correctamente"
done

echo -e "\n${GREEN}=========================================="
echo "Completado"
echo -e "==========================================${NC}"

