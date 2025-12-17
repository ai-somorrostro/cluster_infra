#!/bin/bash

# vm_apt_install.sh - Instala paquetes apt en una o varias VMs usando pvesh

if [ $# -lt 3 ]; then
    echo "Uso: $0 <vmid1> [vmid2] ... -- <paquete1> [paquete2] [paquete3] ..."
    echo "Ejemplo: $0 100 101 102 -- vim curl htop"
    echo "Ejemplo: $0 100 -- vim curl htop"
    exit 1
fi

# Separar VMIDs y paquetes usando -- como delimitador
VMIDS=()
PACKAGES=()
PARSING_VMIDS=1

for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        PARSING_VMIDS=0
        continue
    fi

    if [ $PARSING_VMIDS -eq 1 ]; then
        VMIDS+=("$arg")
    else
        PACKAGES+=("$arg")
    fi
done

# Validar que tenemos VMIDs y paquetes
if [ ${#VMIDS[@]} -eq 0 ]; then
    echo "Error: Debes especificar al menos un VMID"
    exit 1
fi

if [ ${#PACKAGES[@]} -eq 0 ]; then
    echo "Error: Debes especificar al menos un paquete"
    exit 1
fi

PACKAGES_STR="${PACKAGES[@]}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

# Loop por cada VMID
for VMID in "${VMIDS[@]}"; do
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
      continue
    fi

    echo "Nodo: $NODE | Nombre: $VM_NAME"
    echo "VMID: $VMID"
    echo "Paquetes: $PACKAGES_STR"
    echo -e "==========================================${NC}"

    # Verificar VM
    echo -e "\n${YELLOW}[*]${NC} Verificando VM..."
    VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)

    if [ -z "$VM_STATUS" ]; then
        echo -e "${RED}[✗]${NC} VM $VMID no existe en nodo $NODE"
        continue
    fi

    STATUS=$(echo "$VM_STATUS" | grep -oP '"status":"\K[^"]+')
    if [ "$STATUS" != "running" ]; then
        echo -e "${RED}[✗]${NC} VM $VMID no está corriendo (status: $STATUS)"
        continue
    fi
    echo -e "${GREEN}[✓]${NC} VM corriendo"

    # Verificar Agent
    echo -e "${YELLOW}[*]${NC} Verificando qemu-guest-agent..."
    AGENT_ENABLED=$(echo "$VM_STATUS" | grep -oP '"agent":\K[0-9]+' || echo "0")
    if [ "$AGENT_ENABLED" == "0" ]; then
        echo -e "${RED}[✗]${NC} qemu-guest-agent no está habilitado"
        continue
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
        continue
    fi

    # 5. Instalar
    echo -e "\n${YELLOW}[*]${NC} Instalando paquetes..."
    INSTALL_CMD="DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES_STR"
    if run_cmd "sh" "-c" "$INSTALL_CMD"; then
        echo -e "${GREEN}[✓]${NC} Instalación completada"
    else
        echo -e "${RED}[✗]${NC} Error en apt install"
        continue
    fi

    # 6. Verificar
    echo -e "\n${YELLOW}[*]${NC} Verificando instalación..."
    for PKG in $PACKAGES_STR; do
        if run_cmd "dpkg" "-l" "$PKG"; then
             echo -e "${GREEN}[✓]${NC} $PKG instalado correctamente"
        else
             echo -e "${RED}[✗]${NC} $PKG no parece estar instalado"
        fi
    done

    echo -e "\n${YELLOW}[*]${NC} VM $VMID procesada"
done

echo -e "\n${GREEN}=========================================="
echo "Proceso completado"
echo "==========================================${NC}"
