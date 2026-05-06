#!/bin/bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/pve-load-env.sh"

# Configuracion
VM_IDS=$1
CACHE_DIR="${2:-/opt/pip-cache}"

# Validacion de argumentos
if [ -z "$VM_IDS" ]; then
  echo "Error: Faltan argumentos. Uso: $0 'vm_id1 vm_id2 vm_id3' [cache_dir]"
  echo "Ejemplo: $0 '100 101 102'"
  echo "Ejemplo: $0 '100 101 102' /opt/pip-cache"
  exit 1
fi

# Convertir VM_IDS en array
IFS=' ' read -ra VMS <<< "$VM_IDS"

echo "Configurando pip cache en ${#VMS[@]} VM(s) con directorio $CACHE_DIR..."
echo "=============================================="

# Iterar sobre cada VM
for VMID in "${VMS[@]}"; do
  echo ""
  echo "Procesando VM $VMID..."
  echo "---------------------------------------------"
  
  # Detectar nodo y nombre de la VM
  VM_INFO=$(pvesh get /cluster/resources --type vm --output-format json | \
    python3 -c "import sys, json; \
    vms = json.load(sys.stdin); \
    vm = next((i for i in vms if i.get('vmid') == $VMID), None); \
    print(f\"{vm.get('node', 'N/A')}|{vm.get('name', 'N/A')}\") if vm else print('N/A|N/A')")
  
  NODE=$(echo "$VM_INFO" | cut -d'|' -f1)
  VM_NAME=$(echo "$VM_INFO" | cut -d'|' -f2)
  
  if [ "$NODE" = "N/A" ] || [ -z "$NODE" ]; then
    echo "✗ No se encuentra la VM $VMID en ningun nodo del cluster."
    echo "---------------------------------------------"
    continue
  fi
  
  echo "Nodo: $NODE | Nombre: $VM_NAME"
  
  # Función para ejecutar comandos en la VM
  exec_in_vm() {
    local cmd="$1"
    # Escapar comillas dobles
    local escaped_cmd=$(echo "$cmd" | sed 's/"/\\"/g')
    
    # Ejecutar y obtener PID
    local out=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sh" --command "-c" --command "$escaped_cmd" --output-format json 2>/dev/null)
    local pid=$(echo "$out" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('pid', ''))" 2>/dev/null)
    
    if [ -z "$pid" ]; then
      return 1
    fi
    
    # Esperar a que termine (máximo 30 segundos)
    local count=0
    while [ $count -lt 30 ]; do
      sleep 1
      local status=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $pid --output-format json 2>/dev/null)
      if echo "$status" | python3 -c "import sys, json; data=json.load(sys.stdin); exit(0 if data.get('exited') else 1)" 2>/dev/null; then
        # Comando terminado, obtener salida y código de salida
        echo "$status" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('out-data', '')); exit(data.get('exitcode', 1))" 2>/dev/null
        return $?
      fi
      count=$((count+1))
    done
    return 1
  }
  
  # Verificar que pip está instalado
  echo "Verificando pip..."
  if ! exec_in_vm "which pip3 >/dev/null 2>&1 || which pip >/dev/null 2>&1" 2>/dev/null >/dev/null; then
    echo "⚠ pip no encontrado. Intentando instalar python3-pip..."
    if ! exec_in_vm "apt-get update && apt-get install -y python3-pip" 2>/dev/null >/dev/null; then
      echo "✗ No se pudo instalar pip. Saltando VM $VMID."
      echo "---------------------------------------------"
      continue
    fi
  fi
  echo "✓ pip encontrado"
  
  # Crear directorio de cache
  echo "Creando directorio de cache $CACHE_DIR..."
  CACHE_CMD="mkdir -p \"$CACHE_DIR\" && chmod 1777 \"$CACHE_DIR\""
  if exec_in_vm "$CACHE_CMD" 2>/dev/null >/dev/null; then
    echo "✓ Directorio creado"
  else
    echo "✗ Error al crear directorio. Saltando VM $VMID."
    echo "---------------------------------------------"
    continue
  fi
  
  # Crear archivo de configuracion pip.conf
  echo "Configurando /etc/pip.conf..."
  PIP_CONF_CMD="cat > /etc/pip.conf << 'EOF'
[global]
cache-dir = $CACHE_DIR
EOF"
  if exec_in_vm "$PIP_CONF_CMD" 2>/dev/null >/dev/null; then
    echo "✓ pip.conf configurado"
  else
    echo "⚠ Advertencia: No se pudo crear /etc/pip.conf (puede requerir permisos)"
  fi
  
  # Crear script de profile.d
  echo "Configurando variable de entorno..."
  PROFILE_CMD="echo \"export PIP_CACHE_DIR=$CACHE_DIR\" > /etc/profile.d/pip-cache.sh && chmod +x /etc/profile.d/pip-cache.sh"
  if exec_in_vm "$PROFILE_CMD" 2>/dev/null >/dev/null; then
    echo "✓ Variable de entorno configurada"
  else
    echo "⚠ Advertencia: No se pudo crear /etc/profile.d/pip-cache.sh"
  fi
  
  # Verificar configuracion
  echo "Verificando configuracion..."
  VERIFY_OUTPUT=$(exec_in_vm "python3 -m pip config list 2>/dev/null || pip3 config list 2>/dev/null || echo 'pip config no disponible'" 2>/dev/null)
  if echo "$VERIFY_OUTPUT" | grep -q "cache-dir"; then
    echo "✓ Configuracion verificada"
    echo "$VERIFY_OUTPUT" | grep "cache-dir" || true
  else
    echo "⚠ No se pudo verificar la configuracion (puede ser normal)"
  fi
  
  echo ""
  echo "✓ Cache de pip configurado en VM $VMID"
  echo "---------------------------------------------"
done

echo ""
echo "Proceso completado para todas las VMs."
