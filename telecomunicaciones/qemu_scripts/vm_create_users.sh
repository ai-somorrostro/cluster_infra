#!/bin/bash

# vm_create_users.sh - Crea/resetea usuarios en VMs desde fichero usuario:password

set -e

# Parse flags
FORCE_PASSWORD_CHANGE=1
ADD_TO_DOCKER=0

while [[ "$1" =~ ^-- ]]; do
    case "$1" in
        --nopass)
            FORCE_PASSWORD_CHANGE=0
            shift 1
            ;;
        --add-to-docker)
            ADD_TO_DOCKER=1
            shift 1
            ;;
        *)
            echo "Opción desconocida: $1"
            exit 1
            ;;
    esac
done

if [ $# -lt 2 ]; then
    echo "Uso: $0 [--nopass] [--add-to-docker] <fichero_usuarios> <vmid1> [vmid2] ..."
    echo "Ejemplo: $0 usuarios.txt 127 128"
    echo "Ejemplo (sin expirar password): $0 --nopass usuarios.txt 127 128"
    echo "Ejemplo (añadir a docker): $0 --add-to-docker usuarios.txt 127 128"
    echo "Ejemplo (ambas opciones): $0 --nopass --add-to-docker usuarios.txt 127 128"
    echo ""
    echo "Formato fichero: usuario:password (uno por línea)"
    echo ""
    echo "Opciones:"
    echo "  --nopass         No fuerza el cambio de contraseña en el primer login"
    echo "  --add-to-docker  Añade todos los usuarios al grupo docker"
    exit 1
fi

USER_FILE=$1
shift 1
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

    echo "Nodo: $NODE | Nombre: $VM_NAME | VMID: $VMID"
    echo -e "==========================================${NC}"

    # Verificar estado
    VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null)
    if ! echo "$VM_STATUS" | grep -q '"status":"running"' || ! echo "$VM_STATUS" | grep -q '"agent":1'; then
        echo -e "${RED}[✗]${NC} VM no disponible o agente inactivo"
        continue
    fi
    
    # Backup SSH config
    echo -n "Backup SSH config... "
    run_cmd "cp" "/etc/ssh/sshd_config" "/etc/ssh/sshd_config.bak" && echo -e "${GREEN}[OK]${NC}" || echo -e "${YELLOW}[WARN]${NC}"
    
    # Habilitar password SSH (método agresivo)
    echo -n "Habilitando password SSH... "
    if run_cmd "sh" "-c" "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config && grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config"; then
        echo -e "${GREEN}[OK]${NC}"
    else
        echo -e "${YELLOW}[WARN]${NC}"
    fi
    
    # Reiniciar SSH (ambos nombres por si acaso)
    echo -n "Reiniciando SSH... "
    run_cmd "systemctl" "restart" "sshd" >/dev/null 2>&1 || true
    run_cmd "systemctl" "restart" "ssh" >/dev/null 2>&1 || true
    sleep 2
    echo -e "${GREEN}[OK]${NC}"
    
    # Verificar si docker existe (si se solicitó añadir a docker)
    DOCKER_EXISTS=0
    if [ $ADD_TO_DOCKER -eq 1 ]; then
        echo -n "Verificando docker... "
        if run_cmd "getent" "group" "docker"; then
            DOCKER_EXISTS=1
            echo -e "${GREEN}[OK]${NC}"
        else
            echo -e "${RED}[No existe]${NC}"
            echo -e "${YELLOW}[!]${NC} Se solicitó --add-to-docker pero el grupo docker no existe en la VM"
        fi
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
                echo -e "${GREEN}[✓]${NC}"
            else
                echo -e "${YELLOW}[WARN]${NC}"
            fi
        fi

        # Expirar contraseña para forzar cambio en primer login (si no se especificó --nopass)
        if [ $FORCE_PASSWORD_CHANGE -eq 1 ]; then
            echo -n "  • Expirar password... "
            if run_cmd "passwd" "--expire" "$username"; then
                echo -e "${GREEN}[OK]${NC}"
            else
                echo -e "${YELLOW}[WARN]${NC}"
            fi
        else
            echo -e "  • Password no expirado (--nopass activo)"
        fi

        echo ""
    done < "$USER_FILE"
done

echo -e "${GREEN}=========================================="
echo "Completado"
echo "==========================================${NC}"
