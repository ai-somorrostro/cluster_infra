#!/bin/bash

# vm_create_users.sh - Crea/resetea usuarios en VMs desde fichero usuario:password

set -e

if [ $# -lt 3 ]; then
    echo "Uso: $0 <nodo> <fichero_usuarios> <vmid1> [vmid2] ..."
    echo "Ejemplo: $0 pve-node-3 usuarios.txt 127 128"
    echo ""
    echo "Formato fichero: usuario:password (uno por línea)"
    exit 1
fi

NODE=$1
USER_FILE=$2
shift 2
VMIDS=("$@")

if [ ! -f "$USER_FILE" ]; then
    echo "Error: fichero '$USER_FILE' no existe"
    exit 1
fi

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

# --- Loop por VM ---
for VMID in "${VMIDS[@]}"; do
    echo -e "\n${YELLOW}=========================================="
    echo "VM $VMID"
    echo -e "==========================================${NC}"
    
    # Verificar estado
    VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)
    if ! echo "$VM_STATUS" | grep -q '"status":"running"' || ! echo "$VM_STATUS" | grep -q '"agent":1'; then
        echo -e "${RED}[✗]${NC} VM no disponible o agente inactivo"
        continue
    fi
    
    # Verificar si docker existe
    echo -n "Verificando docker... "
    if run_cmd "getent" "group" "docker"; then
        DOCKER_EXISTS=1
        echo -e "${GREEN}[OK]${NC}"
    else
        DOCKER_EXISTS=0
        echo "[No existe]"
    fi
    
    echo ""
    
    # Procesar usuarios
    while IFS=':' read -r username password || [ -n "$username" ]; do
        # Limpiar espacios y comillas
        username=$(echo "$username" | sed 's/^[[:space:]"]*//;s/[[:space:]"]*$//')
        password=$(echo "$password" | sed 's/^[[:space:]"]*//;s/[[:space:]"]*$//')
        
        # Saltar líneas vacías o comentarios
        if [ -z "$username" ] || [[ "$username" =~ ^# ]]; then
            continue
        fi
        
        if [ -z "$password" ]; then
            echo -e "${YELLOW}[!]${NC} $username: falta contraseña, saltando"
            continue
        fi
        
        echo -e "${YELLOW}Usuario: $username${NC}"
        
        # Verificar si existe
        echo -n "  • Verificando... "
        if run_cmd "id" "$username"; then
            echo "ya existe"
        else
            echo -n "creando... "
            if run_cmd "useradd" "-m" "-s" "/bin/bash" "$username"; then
                echo -e "${GREEN}[OK]${NC}"
            else
                echo -e "${RED}[ERROR]${NC}"
                continue
            fi
        fi
        
        # Establecer contraseña
        echo -n "  • Contraseña... "
        if run_cmd "sh" "-c" "echo '$username:$password' | chpasswd"; then
            echo -e "${GREEN}[OK]${NC}"
        else
            echo -e "${RED}[ERROR]${NC}"
        fi
        
        # Añadir a sudo
        echo -n "  • Grupo sudo... "
        if run_cmd "usermod" "-aG" "sudo" "$username"; then
            echo -e "${GREEN}[OK]${NC}"
        else
            echo -e "${YELLOW}[WARN]${NC}"
        fi
        
        # Añadir a docker si existe
        if [ $DOCKER_EXISTS -eq 1 ]; then
            echo -n "  • Grupo docker... "
            if run_cmd "usermod" "-aG" "docker" "$username"; then
                echo -e "${GREEN}[OK]${NC}"
            else
                echo -e "${YELLOW}[WARN]${NC}"
            fi
        fi
        
        # Expirar contraseña para forzar cambio en primer login
        echo -n "  • Expirar password... "
        if run_cmd "passwd" "--expire" "$username"; then
            echo -e "${GREEN}[OK]${NC}"
        else
            echo -e "${YELLOW}[WARN]${NC}"
        fi
        
        echo ""
    done < "$USER_FILE"
done

echo -e "${GREEN}=========================================="
echo "Completado"
echo "==========================================${NC}"

