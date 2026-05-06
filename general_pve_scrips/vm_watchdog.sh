#!/bin/bash
# vm_watchdog.sh
# Universal script for Proxmox VM watchdog setup
# - Run on Proxmox HOST to add watchdog to VM config
# - Run INSIDE VM to configure watchdog software
#
# Usage (on host):  ./vm_watchdog.sh host <vmid> [action]
# Usage (in guest): ./vm_watchdog.sh guest

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/pve-load-env.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

# Detect mode if not specified
MODE=${1:-auto}

if [ "$MODE" == "auto" ]; then
    if [ -d "/etc/pve" ]; then
        echo -e "${RED}Error: Please specify VM ID${NC}"
        echo "Usage: $0 host <vmid> [action]"
        exit 1
    else
        echo "Detected: Running inside VM"
        MODE="guest"
    fi
fi

#####################################
# HOST MODE - Configure VM
#####################################
if [ "$MODE" == "host" ]; then
    VMID=$2
    ACTION=${3:-reset}
    
    if [ -z "$VMID" ]; then
        echo "Usage: $0 host <vmid> [action]"
        echo ""
        echo "Arguments:"
        echo "  vmid     - VM ID number (e.g., 100)"
        echo "  action   - Watchdog action (default: reset)"
        echo "             Options: reset, shutdown, poweroff, pause, none"
        echo ""
        echo "Example: $0 host 100 reset"
        exit 1
    fi
    
    # Validate action
    case $ACTION in
        reset|shutdown|poweroff|pause|none) ;;
        *)
            echo -e "${RED}Error: Invalid action '$ACTION'${NC}"
            echo "Valid actions: reset, shutdown, poweroff, pause, none"
            exit 1
            ;;
    esac
    
    # Detect node where VM is located
    echo -e "${YELLOW}[*]${NC} Detectando nodo donde está la VM $VMID..."
    NODE=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | \
        python3 -c "import sys, json; \
        vms = json.load(sys.stdin); \
        vm = next((i for i in vms if i.get('vmid') == $VMID), None); \
        print(vm.get('node', '')) if vm else print('')" 2>/dev/null)
    
    if [ -z "$NODE" ]; then
        echo -e "${RED}Error: VM $VMID no encontrada en el cluster${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓${NC} VM $VMID encontrada en nodo: $NODE"
    
    # Check if VM exists and get status
    VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null | \
        python3 -c "import sys, json; print(json.load(sys.stdin).get('status', 'unknown'))" 2>/dev/null)
    
    if [ -z "$VM_STATUS" ] || [ "$VM_STATUS" == "unknown" ]; then
        echo -e "${RED}Error: No se pudo obtener el estado de la VM $VMID${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}[*]${NC} Estado actual de la VM: $VM_STATUS"
    
    # Get config file path
    CONFIG_FILE="/etc/pve/qemu-server/${VMID}.conf"
    
    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Error: Archivo de configuración no encontrado: $CONFIG_FILE${NC}"
        exit 1
    fi
    
    WATCHDOG_LINE="watchdog: model=i6300esb,action=${ACTION}"
    
    # Check if watchdog already configured
    if grep -q "^watchdog:" "$CONFIG_FILE"; then
        echo -e "${YELLOW}⚠${NC} Watchdog ya está configurado para la VM $VMID:"
        grep "^watchdog:" "$CONFIG_FILE"
        read -p "¿Quieres reemplazarlo? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Operación cancelada."
            exit 0
        fi
        sed -i '/^watchdog:/d' "$CONFIG_FILE"
    fi
    
    # Stop VM if running
    WAS_RUNNING=false
    if [ "$VM_STATUS" == "running" ]; then
        echo -e "${YELLOW}[*]${NC} La VM está corriendo. Deteniéndola..."
        WAS_RUNNING=true
        
        # Stop using pvesh
        pvesh create /nodes/$NODE/qemu/$VMID/status/stop --timeout 60 >/dev/null 2>&1 || {
            echo -e "${RED}Error: No se pudo detener la VM${NC}"
            exit 1
        }
        
        echo -n "Esperando a que la VM se detenga"
        for i in {1..60}; do
            sleep 1
            echo -n "."
            VM_STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/status/current --output-format json 2>/dev/null | \
                python3 -c "import sys, json; print(json.load(sys.stdin).get('status', 'unknown'))" 2>/dev/null)
            if [ "$VM_STATUS" == "stopped" ]; then
                echo -e " ${GREEN}✓${NC}"
                break
            fi
        done
        
        if [ "$VM_STATUS" != "stopped" ]; then
            echo -e "\n${RED}Error: La VM no se detuvo correctamente en 60 segundos${NC}"
            exit 1
        fi
    fi
    
    # Add watchdog configuration
    echo -e "${YELLOW}[*]${NC} Añadiendo configuración de watchdog a la VM $VMID..."
    echo "$WATCHDOG_LINE" >> "$CONFIG_FILE"
    
    # Verify
    if grep -q "^watchdog:" "$CONFIG_FILE"; then
        echo -e "${GREEN}✓${NC} Watchdog configurado correctamente:"
        grep "^watchdog:" "$CONFIG_FILE"
    else
        echo -e "${RED}✗${NC} Error: No se pudo añadir la configuración de watchdog"
        exit 1
    fi
    
    # Start VM if it was running
    if [ "$WAS_RUNNING" = true ]; then
        echo -e "${YELLOW}[*]${NC} Iniciando la VM $VMID..."
        pvesh create /nodes/$NODE/qemu/$VMID/status/start >/dev/null 2>&1 || {
            echo -e "${RED}Error: No se pudo iniciar la VM${NC}"
            exit 1
        }
        sleep 2
        echo -e "${GREEN}✓${NC} VM iniciada"
    fi
    
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Configuración en HOST completada!${NC}"
    echo "=========================================="
    echo ""
    echo "PRÓXIMO PASO: Dentro de la VM $VMID, ejecuta:"
    echo "  sudo ./vm_watchdog.sh guest"
    echo ""
    echo "Luego reinicia completamente la VM:"
    echo "  pvesh create /nodes/$NODE/qemu/$VMID/status/shutdown"
    echo "  # Espera a que se apague completamente"
    echo "  pvesh create /nodes/$NODE/qemu/$VMID/status/start"
    
    exit 0
fi

#####################################
# GUEST MODE - Configure inside VM
#####################################
if [ "$MODE" == "guest" ]; then
    echo "=========================================="
    echo "Configurando Watchdog dentro de la VM"
    echo "=========================================="
    echo ""
    
    # Check if running in a VM with watchdog support
    if ! lspci | grep -qi "i6300esb\|6300esb"; then
        echo -e "${YELLOW}⚠${NC} Advertencia: No se detectó hardware watchdog i6300esb"
        echo "Esto es normal si aún no has configurado el watchdog en el host"
        echo "o si la VM no ha sido reiniciada después de la configuración."
        echo ""
    fi
    
    # Install watchdog package
    echo -e "${YELLOW}[1/5]${NC} Instalando paquete watchdog..."
    if command -v apt &> /dev/null; then
        apt update
        apt install -y watchdog
    elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
        PKG_MGR=$(command -v dnf || command -v yum)
        $PKG_MGR install -y watchdog
    else
        echo -e "${RED}Error: Gestor de paquetes no soportado. Este script soporta apt, yum o dnf.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓${NC} Paquete watchdog instalado"
    echo ""
    
    # Configure watchdog
    echo -e "${YELLOW}[2/5]${NC} Configurando watchdog..."
    
    # Backup existing config
    if [ -f /etc/watchdog.conf ]; then
        cp /etc/watchdog.conf /etc/watchdog.conf.bak
    fi
    
    # Add configuration
    if ! grep -q "^watchdog-device" /etc/watchdog.conf 2>/dev/null; then
        cat >> /etc/watchdog.conf <<EOF

# Watchdog configuration added by vm_watchdog.sh
watchdog-device = /dev/watchdog
log-dir = /var/log/watchdog
realtime = yes
priority = 1
EOF
        echo -e "${GREEN}✓${NC} Configuración añadida a /etc/watchdog.conf"
    else
        echo -e "${YELLOW}⚠${NC} watchdog-device ya está configurado en /etc/watchdog.conf"
    fi
    echo ""
    
    # Configure watchdog module
    echo -e "${YELLOW}[3/5]${NC} Configurando módulo del kernel..."
    
    # Check if module is available
    if modinfo i6300esb >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Módulo i6300esb disponible en el kernel"
    else
        echo -e "${YELLOW}⚠${NC} Módulo i6300esb no encontrado. Puede necesitar reiniciar después de configurar en el host."
    fi
    
    # Configure module loading
    if [ ! -f /etc/modules-load.d/watchdog.conf ]; then
        echo "i6300esb" > /etc/modules-load.d/watchdog.conf
        echo -e "${GREEN}✓${NC} Módulo configurado para cargarse al inicio"
    else
        if ! grep -q "i6300esb" /etc/modules-load.d/watchdog.conf 2>/dev/null; then
            echo "i6300esb" >> /etc/modules-load.d/watchdog.conf
            echo -e "${GREEN}✓${NC} Módulo añadido a la configuración"
        else
            echo -e "${YELLOW}⚠${NC} Módulo ya está en la configuración"
        fi
    fi
    
    # Also configure /etc/default/watchdog for compatibility
    if [ ! -f /etc/default/watchdog ]; then
        echo "watchdog_module=i6300esb" > /etc/default/watchdog
    else
        if ! grep -q "watchdog_module" /etc/default/watchdog 2>/dev/null; then
            echo "watchdog_module=i6300esb" >> /etc/default/watchdog
        fi
    fi
    echo ""
    
    # Try to load module now (may fail if not configured in host yet)
    echo -e "${YELLOW}[4/5]${NC} Intentando cargar módulo del kernel..."
    if modprobe i6300esb 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Módulo cargado correctamente"
    else
        echo -e "${YELLOW}⚠${NC} No se pudo cargar el módulo ahora (normal si no está configurado en el host)"
        echo "El módulo se cargará automáticamente después del reinicio"
    fi
    echo ""
    
    # Enable and start watchdog service
    echo -e "${YELLOW}[5/5]${NC} Habilitando y iniciando servicio watchdog..."
    systemctl daemon-reload
    systemctl enable watchdog
    systemctl start watchdog || {
        echo -e "${YELLOW}⚠${NC} No se pudo iniciar el servicio (normal si el hardware no está disponible aún)"
        echo "El servicio se iniciará automáticamente después del reinicio"
    }
    echo ""
    
    # Check status
    echo "=========================================="
    echo "Verificando estado..."
    echo "=========================================="
    
    sleep 2
    if systemctl is-active --quiet watchdog; then
        echo -e "${GREEN}✓${NC} Servicio watchdog está corriendo"
        systemctl status watchdog --no-pager -l | head -n 10
    else
        echo -e "${YELLOW}⚠${NC} Servicio watchdog no está corriendo (normal si el hardware no está disponible)"
    fi
    echo ""
    
    # Check for watchdog device
    if [ -e /dev/watchdog ]; then
        echo -e "${GREEN}✓${NC} Dispositivo /dev/watchdog existe"
        ls -l /dev/watchdog
    else
        echo -e "${YELLOW}⚠${NC} Dispositivo /dev/watchdog no encontrado (normal si no está configurado en el host)"
    fi
    echo ""
    
    # Check dmesg
    echo "Buscando mensajes del kernel sobre watchdog..."
    if dmesg | grep -i "i6300\|watchdog" | tail -n 5; then
        echo -e "${GREEN}✓${NC} Mensajes del kernel encontrados"
    else
        echo -e "${YELLOW}⚠${NC} No se encontraron mensajes del kernel (normal si no está configurado en el host)"
    fi
    echo ""
    
    echo "=========================================="
    echo -e "${GREEN}Configuración en GUEST completada!${NC}"
    echo "=========================================="
    echo ""
    echo -e "${YELLOW}IMPORTANTE:${NC} Debes apagar completamente la VM (no solo reiniciar)"
    echo "y volver a iniciarla para que el watchdog funcione."
    echo ""
    echo "Desde el host Proxmox, ejecuta:"
    echo "  pvesh create /nodes/<nodo>/qemu/<vmid>/status/shutdown"
    echo "  # Espera a que se apague completamente"
    echo "  pvesh create /nodes/<nodo>/qemu/<vmid>/status/start"
    echo ""
    echo "Después del reinicio, verifica con:"
    echo "  dmesg | grep i6300"
    echo "  systemctl status watchdog"
    echo "  ls -l /dev/watchdog"
    
    exit 0
fi

# Invalid mode
echo -e "${RED}Error: Modo inválido '$MODE'${NC}"
echo "Usage:"
echo "  En host Proxmox: $0 host <vmid> [action]"
echo "  Dentro de la VM: $0 guest"
exit 1
