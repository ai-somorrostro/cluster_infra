#!/bin/bash

# Configuracion
DISK="scsi0"  # Hardcodeado
VM_IDS=$1
SIZE=$2

# Validacion de argumentos
if [ -z "$VM_IDS" ] || [ -z "$SIZE" ]; then
  echo "Error: Faltan argumentos. Uso: $0 'vm_id1 vm_id2 vm_id3' +10G"
  exit 1
fi

# Convertir VM_IDS en array
IFS=' ' read -ra VMS <<< "$VM_IDS"

echo "Redimensionando $DISK en ${#VMS[@]} VM(s) con tamano $SIZE..."
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
  
  # Ejecutar redimensionado en Proxmox
  pvesh set /nodes/$NODE/qemu/$VMID/resize --disk $DISK --size $SIZE
  
  if [ $? -eq 0 ]; then
    echo "✓ Resize correcto en el hipervisor para VM $VMID."
    echo ""
    
    # Función para ejecutar comandos en la VM
    exec_in_vm() {
      local cmd="$1"
      pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sh" --arg "-c" --arg "$cmd" 2>/dev/null | \
      python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('out-data', '')); exit(0 if data.get('exited', 1) == 0 else 1)" 2>/dev/null
      return ${PIPESTATUS[1]}
    }
    
    # Intentar expandir automáticamente
    echo "Expandiendo partición dentro de la VM..."
    
    # Obtener dispositivo montado en /
    ROOT_DEV=$(exec_in_vm "df -h / | tail -1 | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
    
    if [ -n "$ROOT_DEV" ] && echo "$ROOT_DEV" | grep -qE "(mapper|/.*-.*)"; then
      # Es LVM - extraer VG y LV
      if echo "$ROOT_DEV" | grep -q "mapper"; then
        # /dev/mapper/ubuntu--vg-ubuntu--lv -> ubuntu-vg/ubuntu-lv
        MAPPER_NAME=$(echo "$ROOT_DEV" | sed 's|/dev/mapper/||' | sed 's/--/-/g')
        if echo "$MAPPER_NAME" | grep -qE ".*-.*-"; then
          VG_NAME=$(echo "$MAPPER_NAME" | sed 's/-[^-]*$//')
          LV_NAME=$(echo "$MAPPER_NAME" | sed "s/^${VG_NAME}-//")
        else
          VG_NAME=$(echo "$MAPPER_NAME" | cut -d'-' -f1)
          LV_NAME=$(echo "$MAPPER_NAME" | cut -d'-' -f2-)
        fi
        LV_PATH="/dev/$VG_NAME/$LV_NAME"
      else
        LV_PATH="$ROOT_DEV"
      fi
      
      echo "Detectado LVM: $LV_PATH"
      echo "Expandiendo volumen lógico..."
      
      EXPAND_OUTPUT=$(exec_in_vm "lvextend -l +100%FREE $LV_PATH 2>&1 && resize2fs $LV_PATH 2>&1" 2>/dev/null)
      if [ $? -eq 0 ]; then
        echo "✓ Partición expandida correctamente."
        echo "$EXPAND_OUTPUT" | grep -v "^$"
      else
        echo "⚠ Error al expandir. Comandos manuales:"
        echo "  lvextend -l +100%FREE $LV_PATH"
        echo "  resize2fs $LV_PATH"
      fi
    else
      echo "⚠ No se detectó LVM o no se pudo obtener el dispositivo. Expande manualmente."
    fi
    
    echo ""
    echo "Estado final del disco:"
    exec_in_vm "df -h /" 2>/dev/null
  else
    echo "✗ Fallo al intentar redimensionar el disco en VM $VMID."
  fi
  
  echo "---------------------------------------------"
done

echo ""
echo "Proceso completado para todas las VMs."
