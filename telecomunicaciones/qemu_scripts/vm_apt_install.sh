#!/bin/bash

# vm_apt_install.sh - Instala paquetes apt en una VM usando pvesh

set -e

if [ $# -lt 3 ]; then
    echo "Uso: $0 <nodo> <vmid> <paquete1> [paquete2] [paquete3] ..."
    echo "Ejemplo: $0 pve 100 vim curl htop"
    exit 1
fi

NODE=$1
VMID=$2
shift 2
PACKAGES="$@"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "Nodo: $NODE"
echo "VMID: $VMID"
echo "Paquetes: $PACKAGES"
echo "=========================================="

# --- Funciones Helper ---

# Función para esperar finalización de PID
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

# Ejecutar comando simple y esperar (sin output check)
run_cmd() {
    local cmd_arr=("$@")
    # Construir argumentos --command
    local pvesh_args=""
    for arg in "${cmd_arr[@]}"; do
        # Escapar comillas dobles dentro del argumento si existen
        local escaped_arg=$(echo "$arg" | sed 's/"/\\"/g')
        pvesh_args="$pvesh_args --command \"$escaped_arg\""
    done
    
    # Ejecutar con eval para procesar las comillas correctamente
    local out=$(eval pvesh create /nodes/$NODE/qemu/$VMID/agent/exec $pvesh_args --output-format json 2>/dev/null)
    local pid=$(echo "$out" | grep -oP '"pid":\K[0-9]+')
    
    if [ -z "$pid" ]; then
        return 1
    fi
    
    # Esperar (timeout 120s por defecto para dar tiempo a apt)
    local res=$(wait_for_pid $pid 120)
    local exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
    return $exitcode
}

# --- Inicio Script ---

# Verificar VM
echo -e "\n${YELLOW}[*]${NC} Verificando VM..."
VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)

if [ -z "$VM_STATUS" ]; then
    echo -e "${RED}[✗]${NC} VM $VMID no existe en nodo $NODE"
    exit 1
fi

STATUS=$(echo "$VM_STATUS" | grep -oP '"status":"\K[^"]+')
if [ "$STATUS" != "running" ]; then
    echo -e "${RED}[✗]${NC} VM $VMID no está corriendo (status: $STATUS)"
    exit 1
fi
echo -e "${GREEN}[✓]${NC} VM corriendo"

# Verificar Agent
echo -e "${YELLOW}[*]${NC} Verificando qemu-guest-agent..."
AGENT_ENABLED=$(echo "$VM_STATUS" | grep -oP '"agent":\K[0-9]+' || echo "0")
if [ "$AGENT_ENABLED" == "0" ]; then
    echo -e "${RED}[✗]${NC} qemu-guest-agent no está habilitado"
    exit 1
fi
echo -e "${GREEN}[✓]${NC} qemu-guest-agent activo"

# 1. Corrección preventiva: Comentar CDROM en sources.list
echo -e "\n${YELLOW}[*]${NC} Aplicando correcciones preventivas (sources.list)..."
# Usamos sed para comentar líneas que empiezan por 'deb cdrom'
FIX_CMD="sed -i '/^deb cdrom/s/^/#/' /etc/apt/sources.list"
if run_cmd "sh" "-c" "$FIX_CMD"; then
    echo -e "${GREEN}[✓]${NC} Sources.list corregido (CDROM desactivado)"
else
    echo -e "${YELLOW}[!]${NC} No se pudo modificar sources.list (o no era necesario)"
fi

# 2. Verificar conectividad
echo -e "${YELLOW}[*]${NC} Verificando conectividad a internet..."
if run_cmd "ping" "-c" "1" "8.8.8.8"; then
    echo -e "${GREEN}[✓]${NC} Internet OK"
else
    echo -e "${RED}[✗]${NC} La VM no tiene internet. 'apt update' fallará."
    # Intentamos continuar por si es un problema de ping pero apt funciona (proxy?), pero avisamos
fi

# 3. Limpiar locks (por si acaso)
echo -e "${YELLOW}[*]${NC} Limpiando locks anteriores..."
CLEAN_CMD="rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* /var/lib/dpkg/lock-frontend"
run_cmd "sh" "-c" "$CLEAN_CMD"
run_cmd "dpkg" "--configure" "-a"

# 4. Actualizar apt
echo -e "\n${YELLOW}[*]${NC} Actualizando cache de apt..."
if run_cmd "apt-get" "update"; then
    echo -e "${GREEN}[✓]${NC} Cache actualizado"
else
    echo -e "${RED}[✗]${NC} Error en apt update"
    exit 1
fi

# 5. Instalar
echo -e "\n${YELLOW}[*]${NC} Instalando paquetes..."
INSTALL_CMD="DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES"
if run_cmd "sh" "-c" "$INSTALL_CMD"; then
    echo -e "${GREEN}[✓]${NC} Instalación completada"
else
    echo -e "${RED}[✗]${NC} Error en apt install"
    exit 1
fi

# 6. Verificar
echo -e "\n${YELLOW}[*]${NC} Verificando instalación..."
for PKG in $PACKAGES; do
    if run_cmd "dpkg" "-l" "$PKG"; then
         echo -e "${GREEN}[✓]${NC} $PKG instalado correctamente"
    else
         echo -e "${RED}[✗]${NC} $PKG no parece estar instalado"
    fi
done

echo -e "\n=========================================="
echo "Proceso completado"
echo "=========================================="
