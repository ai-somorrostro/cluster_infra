#!/bin/bash
# vram_killer.sh
# Script to kill processes when TOTAL VRAM of all processes exceeds a limit
# Kills the most recent process that caused the excess
# VRAM values are in MiB (mebibytes) as reported by nvidia-smi
# 
# Usage: ./vram_killer.sh <limit_mib> [check_interval_ms]
# Example: ./vram_killer.sh 8192 5000
#          (if sum of VRAM of all processes > 8192 MiB, kills latest process, checks every 5000ms)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LIMIT_MIB_RAW=${1:-8192}
CHECK_INTERVAL_MS_RAW=${2:-5000}
LOG_FILE="/var/log/vram_killer.log"

# Convertir a decimal para evitar interpretación octal (ej: 0500 -> 500)
# Usar sed para quitar ceros iniciales
LIMIT_MIB=$(echo "$LIMIT_MIB_RAW" | sed 's/^0*//')
CHECK_INTERVAL_MS=$(echo "$CHECK_INTERVAL_MS_RAW" | sed 's/^0*//')

# Si quedó vacío después de quitar ceros, usar valores por defecto
[ -z "$LIMIT_MIB" ] && LIMIT_MIB=8192
[ -z "$CHECK_INTERVAL_MS" ] && CHECK_INTERVAL_MS=5000

# Convertir milisegundos a segundos para sleep (bash sleep acepta decimales)
CHECK_INTERVAL=$(awk "BEGIN {printf \"%.3f\", $CHECK_INTERVAL_MS / 1000}")

# Verificar que nvidia-smi está disponible
if ! command -v nvidia-smi &> /dev/null; then
    echo -e "${RED}Error: nvidia-smi is not available${NC}"
    echo "Make sure NVIDIA drivers are installed"
    exit 1
fi

# Función de logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Función para obtener VRAM usado por proceso
get_process_vram() {
    local pid=$1
    # nvidia-smi muestra memoria en MiB
    nvidia-smi pmon -c 1 -s m 2>/dev/null | grep -E "^[[:space:]]*${pid}[[:space:]]" | awk '{print $4}' | head -1
}

# Función para matar proceso
kill_process() {
    local pid=$1
    local vram=$2
    local cmd=$(ps -p $pid -o cmd= 2>/dev/null | head -c 100)
    
    log "KILLING PID $pid - VRAM: ${vram} MiB - CMD: $cmd"
    kill -9 $pid 2>/dev/null || true
    sleep 1
    
    # Verificar que se mató
    if ! ps -p $pid > /dev/null 2>&1; then
        log "SUCCESS: Process $pid terminated successfully"
    else
        log "ERROR: Failed to terminate process $pid"
    fi
}

# Función principal de monitoreo
monitor_vram() {
    log "Starting VRAM monitoring - Total limit: ${LIMIT_MIB} MiB - Check interval: ${CHECK_INTERVAL_MS}ms"
    log "Strategy: Sum VRAM of all processes, kill the latest one if limit exceeded"
    
    while true; do
        # Archivo temporal para almacenar procesos
        TEMP_FILE=$(mktemp)
        TOTAL_VRAM=0
        
        # Obtener todos los procesos que usan GPU y su VRAM (nvidia-smi devuelve valores en MiB)
        nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | while IFS=',' read -r pid vram_mib; do
            # Limpiar espacios
            pid=$(echo "$pid" | xargs)
            vram_mib=$(echo "$vram_mib" | xargs)
            
            # Saltar si está vacío
            [ -z "$pid" ] || [ -z "$vram_mib" ] && continue
            
            # Verificar que el proceso existe
            ps -p "$pid" > /dev/null 2>&1 || continue
            
            # Guardar en archivo temporal: PID,VRAM_MIB,CREATETIME
            # Usar tiempo de creación del proceso desde /proc (más confiable)
            create_time=$(stat -c %Y /proc/$pid 2>/dev/null || echo "0")
            echo "$pid,$vram_mib,$create_time" >> "$TEMP_FILE"
        done
        
        # Si no hay procesos, continuar
        if [ ! -s "$TEMP_FILE" ]; then
            rm -f "$TEMP_FILE"
            sleep $CHECK_INTERVAL
            continue
        fi
        
        # Calcular VRAM total
        while IFS=',' read -r pid vram_mib create_time; do
            TOTAL_VRAM=$((TOTAL_VRAM + vram_mib))
        done < "$TEMP_FILE"
        
        # Log current status
        PROCESS_COUNT=$(wc -l < "$TEMP_FILE")
        log "Processes using GPU: $PROCESS_COUNT | Total VRAM: ${TOTAL_VRAM} MiB / ${LIMIT_MIB} MiB"
        
        # Si la suma total excede el límite, matar el último proceso
        if [ "$TOTAL_VRAM" -gt "$LIMIT_MIB" ]; then
            log "WARNING: Limit exceeded! Total VRAM: ${TOTAL_VRAM} MiB > ${LIMIT_MIB} MiB"
            
            # Encontrar el proceso más reciente (último que se inició)
            # Ordenar por tiempo de creación (más reciente = número más alto)
            LATEST_PID=""
            LATEST_VRAM=0
            LATEST_TIME=0
            
            while IFS=',' read -r pid vram_mib create_time; do
                # Comparar tiempos (más reciente = mayor número)
                if [ "$create_time" -gt "$LATEST_TIME" ] 2>/dev/null; then
                    LATEST_PID="$pid"
                    LATEST_VRAM="$vram_mib"
                    LATEST_TIME="$create_time"
                fi
            done < "$TEMP_FILE"
            
            # Si no se pudo determinar por tiempo, usar el que más VRAM usa
            if [ -z "$LATEST_PID" ] || [ "$LATEST_PID" == "0" ]; then
                LATEST_TIME=0
                while IFS=',' read -r pid vram_mib create_time; do
                    if [ "$vram_mib" -gt "$LATEST_VRAM" ] 2>/dev/null; then
                        LATEST_PID="$pid"
                        LATEST_VRAM="$vram_mib"
                        LATEST_TIME="$create_time"
                    fi
                done < "$TEMP_FILE"
            fi
            
            # Matar el proceso identificado
            if [ -n "$LATEST_PID" ] && [ "$LATEST_PID" -gt 0 ] 2>/dev/null; then
                log "Killing latest process: PID $LATEST_PID (VRAM: ${LATEST_VRAM} MiB)"
                kill_process "$LATEST_PID" "$LATEST_VRAM"
            else
                log "ERROR: Could not identify process to kill"
            fi
        fi
        
        rm -f "$TEMP_FILE"
        sleep $CHECK_INTERVAL
    done
}

# Modo daemon
if [ "$1" == "daemon" ]; then
    monitor_vram
    exit 0
fi

# Modo interactivo (una vez)
if [ -z "$1" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "Usage: $0 <limite_mb> [check_interval]"
    echo ""
    echo "Arguments:"
    echo "  limit_mib         - Total VRAM limit in MiB (mebibytes) for all processes"
    echo "                      Examples: 8192 MiB = 8 GiB, 4096 MiB = 4 GiB"
    echo "  check_interval_ms - Check interval in milliseconds (default: 5000 = 5 seconds)"
    echo ""
    echo "How it works:"
    echo "  - Sums VRAM of ALL processes using GPU (values in MiB from nvidia-smi)"
    echo "  - If sum exceeds limit, kills the LATEST process"
    echo ""
    echo "Examples:"
    echo "  $0 8192        # If total VRAM > 8192 MiB (8 GiB), checks every 5000ms (5s)"
    echo "  $0 4096 2000   # If total VRAM > 4096 MiB (4 GiB), checks every 2000ms (2s)"
    echo "  $0 8192 1000   # If total VRAM > 8192 MiB (8 GiB), checks every 1000ms (1s)"
    echo ""
    echo "To run as service:"
    echo "  sudo systemctl start vram-killer"
    echo "  sudo systemctl enable vram-killer"
    exit 0
fi

# Verificar que se ejecuta como root para poder matar procesos
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root to kill processes${NC}"
    echo "Use: sudo $0 $LIMIT_MIB $CHECK_INTERVAL_MS"
    exit 1
fi

# Crear directorio de log si no existe
mkdir -p "$(dirname "$LOG_FILE")"

# Iniciar monitoreo
monitor_vram
