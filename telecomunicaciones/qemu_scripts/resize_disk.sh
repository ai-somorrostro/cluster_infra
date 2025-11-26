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
    
    local res=$(wait_for_pid $pid 60)
    local out_data=$(echo "$res" | grep -oP '"out-data":"\K[^"]+' || echo "")
    if [ -n "$out_data" ]; then
        # Fix: pvesh returns JSON escaped string, NOT base64.
        # Interpret \n as newlines and remove \r
        echo -e "$out_data" | tr -d '\r' | sed 's/[[:space:]]*$//'
    fi
    # También devolver error si el comando falló
    local exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
    if [ "$exitcode" != "0" ]; then
        return 1
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
    
    # Verificar espacio libre antes de apagar (si VM está corriendo)
    CURRENT_STATUS=$(echo "$VM_STATUS" | grep -oP '"status":"\K[^"]+')
    AGENT_ENABLED=$(echo "$VM_STATUS" | grep -oP '"agent":\K[0-9]+' || echo "0")
    
    if [ "$CURRENT_STATUS" == "running" ] && [ "$AGENT_ENABLED" == "1" ]; then
        echo -n "  • Verificando espacio libre existente... "
        VG_OUTPUT=$(get_cmd_output "sudo" "vgs" "--units" "g" 2>/dev/null || echo "")
        if [ -n "$VG_OUTPUT" ]; then
            # Extraer VFree (última columna numérica con formato como "24.00g")
            VG_FREE_RAW=$(echo "$VG_OUTPUT" | tail -n +2 | awk '{print $NF}' | grep -oP '[0-9.]+' | head -1 || echo "")
            if [ -n "$VG_FREE_RAW" ]; then
                VG_FREE_RESULT=$(echo "$VG_FREE_RAW" | awk '{printf "%.0f", $1}')
                if [ -n "$VG_FREE_RESULT" ] && [ "$VG_FREE_RESULT" -gt 0 ] 2>/dev/null; then
                    echo -e "${YELLOW}${VG_FREE_RESULT}GB libre en VG${NC}"
                    echo -e "  ${YELLOW}[!]${NC} Atención: Ya hay ${VG_FREE_RESULT}GB de espacio libre en el VG que no está siendo usado."
                    echo -e "  ${YELLOW}[!]${NC} El script expandirá el LV para usar este espacio + el nuevo espacio añadido."
                else
                    echo -e "${GREEN}Sin espacio libre${NC}"
                fi
            else
                echo -e "${GREEN}Sin espacio libre${NC}"
            fi
        else
            echo -e "${YELLOW}No se pudo verificar${NC}"
        fi
        echo ""
    fi
    
    # 1. Apagar VM si está corriendo
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
    
    # Esperar a que el SO esté realmente listo
    echo -n "  • Esperando estabilización del SO... "
    sleep 10
    echo "OK"
    
    # Detectar dispositivo de bloque principal (con reintentos y fallbacks)
    echo -n "  • Detectando dispositivo... "
    MAIN_DEVICE=""
    for attempt in 1 2 3 4 5; do
        # Intento 1: lsblk normal
        MAIN_DEVICE=$(get_cmd_output "sh" "-c" "lsblk -ndo NAME,TYPE 2>/dev/null | grep 'disk' | head -1 | awk '{print \$1}'")
        
        # Intento 2: lsblk con ruta completa (si falla el anterior)
        if [ -z "$MAIN_DEVICE" ]; then
            MAIN_DEVICE=$(get_cmd_output "sh" "-c" "/usr/bin/lsblk -ndo NAME,TYPE 2>/dev/null | grep 'disk' | head -1 | awk '{print \$1}'")
        fi

        # Intento 3: /proc/partitions (fallback clásico)
        if [ -z "$MAIN_DEVICE" ]; then
            MAIN_DEVICE=$(get_cmd_output "sh" "-c" "cat /proc/partitions | awk '\$4 ~ /^[sv]d[a-z]$|nvme[0-9]n[0-9]$/ {print \$4}' | head -1")
        fi

        if [ -n "$MAIN_DEVICE" ]; then
            break
        fi
        sleep 2
    done
    
    if [ -z "$MAIN_DEVICE" ]; then
        # Último recurso: asumir sda
        echo -e "${YELLOW}[!]${NC} No se pudo detectar, asumiendo 'sda'"
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
    
    # Detectar partición LVM - buscar la partición que tiene el PV
    echo -n "  • Detectando partición LVM... "
    
    # PRIMERO: Obtener el PV directamente desde pvs (fuente de verdad)
    PV_OUTPUT=$(get_cmd_output "sudo" "pvs" "--noheadings" "-o" "pv_name" 2>/dev/null || echo "")
    if [ -n "$PV_OUTPUT" ]; then
        PV_DEVICE_FULL=$(echo "$PV_OUTPUT" | head -1 | awk '{print $1}' | tr -d '[:space:]')
        if [ -n "$PV_DEVICE_FULL" ] && echo "$PV_DEVICE_FULL" | grep -qP '^/dev/[a-z0-9]+$'; then
            PARTITION="${PV_DEVICE_FULL#/dev/}"
            HAS_PARTITIONS=1
            echo "/dev/$PARTITION (detectado desde PV)"
        else
            echo -e "${RED}[✗]${NC} No se pudo parsear el dispositivo PV: '$PV_DEVICE_FULL'"
            continue
        fi
    else
        # Si no hay PV, buscar la partición más grande
        PARTITION_RAW=$(get_cmd_output "sh" "-c" "lsblk -ndo NAME,TYPE,SIZE /dev/${MAIN_DEVICE} 2>/dev/null | grep 'part' | sort -k3 -h | tail -1" || echo "")
        if [ -n "$PARTITION_RAW" ]; then
            PARTITION=$(echo "$PARTITION_RAW" | awk '{print $1}' | grep -oP '^[a-z0-9]+$' || echo "")
            if [ -z "$PARTITION" ] || ! echo "$PARTITION" | grep -qP '^[a-z]{2,3}[0-9]+$'; then
                echo -e "${RED}[✗]${NC} No se pudo detectar la partición LVM"
                echo -e "${RED}[✗]${NC} Output recibido: '$PARTITION_RAW'"
                continue
            fi
            HAS_PARTITIONS=1
            echo "/dev/$PARTITION"
        else
            # Sin particiones, puede ser LVM directamente en el disco
            PARTITION="$MAIN_DEVICE"
            HAS_PARTITIONS=0
            echo "/dev/$PARTITION (sin particiones)"
        fi
    fi
    
    # Expandir partición solo si hay particiones
    if [ $HAS_PARTITIONS -eq 1 ]; then
        echo -n "  • Expandiendo partición... "
        PART_NUM="${PARTITION#${MAIN_DEVICE}}"
        PART_EXPANDED=0
        if run_cmd "sudo" "growpart" "/dev/${MAIN_DEVICE}" "$PART_NUM" 2>/dev/null; then
            echo -e "${GREEN}[✓]${NC}"
            PART_EXPANDED=1
        elif run_cmd "sudo" "sh" "-c" "parted /dev/${MAIN_DEVICE} resizepart ${PART_NUM} 100%"; then
            echo -e "${GREEN}[✓]${NC}"
            PART_EXPANDED=1
        else
            echo -e "${YELLOW}[!]${NC} (puede que no sea necesario o ya expandida)"
        fi
        
        if [ $PART_EXPANDED -eq 1 ]; then
            echo -n "  • Rescanning partición después de expandir... "
            run_cmd "sudo" "partprobe" "/dev/${MAIN_DEVICE}" >/dev/null 2>&1 || true
            sleep 3
            echo -e "${GREEN}[✓]${NC}"
        else
            sleep 2
        fi
    fi
    
    # Obtener el nombre exacto del PV para pvresize
    echo -n "  • Verificando PV... "
    PV_OUTPUT=$(get_cmd_output "sudo" "pvs" "--noheadings" "-o" "pv_name" 2>/dev/null || echo "")
    if [ -n "$PV_OUTPUT" ]; then
        PV_NAME_FULL=$(echo "$PV_OUTPUT" | head -1 | awk '{print $1}' | tr -d '[:space:]')
        if [ -z "$PV_NAME_FULL" ] || ! echo "$PV_NAME_FULL" | grep -qP '^/dev/[a-z0-9]+$'; then
            echo -e "${RED}[✗]${NC} No se pudo obtener el nombre del PV: '$PV_NAME_FULL'"
            continue
        fi
        PV_NAME="${PV_NAME_FULL#/dev/}"
        echo "/dev/$PV_NAME"
    else
        echo -e "${RED}[✗]${NC} No se pudo obtener información del PV"
        continue
    fi
    
    # Verificar que el PV coincide con la partición detectada
    if [ "/dev/$PV_NAME" != "/dev/$PARTITION" ]; then
        echo -e "${YELLOW}[!]${NC} Advertencia: PV ($PV_NAME) != Partición detectada ($PARTITION)"
        echo -e "${YELLOW}[!]${NC} Usando PV: /dev/$PV_NAME"
        PARTITION="$PV_NAME"
    fi
    
    # Rescan PV
    echo -n "  • Rescanning PV... "
    sleep 2
    PV_RESIZED=0
    for attempt in 1 2 3; do
        if run_cmd "sudo" "pvresize" "/dev/$PV_NAME" 2>/dev/null; then
            echo -e "${GREEN}[✓]${NC}"
            PV_RESIZED=1
            break
        fi
        if [ $attempt -lt 3 ]; then
            echo -n "(intento $attempt falló, reintentando...) "
            sleep 3
            if [ $HAS_PARTITIONS -eq 1 ]; then
                run_cmd "sudo" "partprobe" "/dev/$MAIN_DEVICE" >/dev/null 2>&1 || true
                sleep 2
            fi
        fi
    done
    
    if [ $PV_RESIZED -eq 0 ]; then
        echo -e "${RED}[✗]${NC} Error en pvresize de /dev/$PV_NAME después de 3 intentos"
        echo -e "${YELLOW}[!]${NC} Continuando de todos modos (puede que el PV ya esté actualizado)"
    fi
    
    # Obtener VG y LV
    echo -n "  • Detectando VG y LV... "
    VG_NAME=$(get_cmd_output "sudo" "sh" "-c" "vgs --noheadings -o vg_name | head -1 | tr -d ' '")
    LV_INFO=$(get_cmd_output "sudo" "sh" "-c" "lvs --noheadings -o vg_name,lv_name | head -1")
    
    if [ -z "$VG_NAME" ] || [ -z "$LV_INFO" ]; then
        echo -e "${RED}[✗]${NC} No se pudo detectar VG/LV"
        continue
    fi
    
    LV_NAME=$(echo "$LV_INFO" | awk '{print $2}')
    echo "$VG_NAME/$LV_NAME"
    
    # Verificar espacio libre en VG antes de redimensionar
    echo -n "  • Verificando espacio libre en VG... "
    VG_OUTPUT=$(get_cmd_output "sudo" "vgs" "$VG_NAME" "--units" "g" 2>/dev/null || echo "")
    if [ -n "$VG_OUTPUT" ]; then
        # VFree es la última columna (formato "24.00g")
        VG_FREE_RAW=$(echo "$VG_OUTPUT" | tail -n +2 | awk '{print $NF}' | grep -oP '[0-9.]+' | head -1 || echo "")
        if [ -n "$VG_FREE_RAW" ]; then
            VG_FREE=$(echo "$VG_FREE_RAW" | awk '{printf "%.0f", $1}')
            if [ -n "$VG_FREE" ] && [ "$VG_FREE" -gt 0 ] 2>/dev/null; then
                echo -e "${YELLOW}${VG_FREE}GB libre${NC}"
                echo -e "  ${YELLOW}[!]${NC} Hay ${VG_FREE}GB de espacio libre en el VG que no está siendo usado."
                echo -e "  ${YELLOW}[!]${NC} El script expandirá el LV para usar este espacio libre + el nuevo espacio añadido."
            else
                echo -e "${GREEN}Sin espacio libre${NC}"
            fi
        else
            echo -e "${GREEN}Sin espacio libre${NC}"
        fi
    else
        echo -e "${GREEN}Sin espacio libre${NC}"
    fi
    
    # Expandir LV
    echo -n "  • Expandiendo LV... "
    if run_cmd "sudo" "lvextend" "-l" "+100%FREE" "$VG_NAME/$LV_NAME"; then
        echo -e "${GREEN}[✓]${NC}"
    else
        echo -e "${RED}[✗]${NC} Error expandiendo LV"
        continue
    fi
    
    # Detectar filesystem y redimensionar
    echo -n "  • Detectando filesystem... "
    FS_TYPE=$(get_cmd_output "sudo" "blkid" "/dev/$VG_NAME/$LV_NAME" "-o" "value" "-s" "TYPE")
    
    if [ -z "$FS_TYPE" ]; then
        echo -e "${RED}[✗]${NC} No se pudo detectar filesystem"
        continue
    fi
    echo "$FS_TYPE"
    
    # Redimensionar filesystem
    echo -n "  • Redimensionando filesystem... "
    if [ "$FS_TYPE" == "xfs" ]; then
        if run_cmd "sudo" "xfs_growfs" "/" 2>/dev/null || run_cmd "sudo" "xfs_growfs" "/dev/$VG_NAME/$LV_NAME"; then
            echo -e "${GREEN}[✓]${NC}"
        else
            echo -e "${RED}[✗]${NC}"
            continue
        fi
    elif [ "$FS_TYPE" == "ext4" ] || [ "$FS_TYPE" == "ext3" ] || [ "$FS_TYPE" == "ext2" ]; then
        if run_cmd "sudo" "resize2fs" "/dev/$VG_NAME/$LV_NAME"; then
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

