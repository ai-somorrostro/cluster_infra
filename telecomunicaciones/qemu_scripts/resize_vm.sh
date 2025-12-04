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
    
    # Intentar expandir automáticamente
    echo "Expandiendo partición dentro de la VM..."
    
    # Obtener VG, LV y PV directamente usando comandos LVM
    VG_NAME=$(exec_in_vm "vgs --noheadings -o vg_name 2>/dev/null | head -1" 2>/dev/null | tr -d '[:space:]')
    LV_NAME=$(exec_in_vm "lvs --noheadings -o lv_name 2>/dev/null | head -1" 2>/dev/null | tr -d '[:space:]')
    PV_NAME=$(exec_in_vm "pvs --noheadings -o pv_name 2>/dev/null | head -1" 2>/dev/null | tr -d '[:space:]')
    
    if [ -n "$VG_NAME" ] && [ -n "$LV_NAME" ] && [ -n "$PV_NAME" ]; then
      LV_PATH="/dev/$VG_NAME/$LV_NAME"
      echo "Detectado LVM: VG=$VG_NAME, LV=$LV_NAME, PV=$PV_NAME"
      
      # Paso 1: Actualizar el Physical Volume para que detecte el nuevo tamaño del disco
      echo "Actualizando Physical Volume..."
      PV_RESIZE_OUTPUT=$(exec_in_vm "pvresize $PV_NAME 2>&1" 2>/dev/null)
      PV_RESIZE_EXIT=$?
      
      if [ $PV_RESIZE_EXIT -eq 0 ]; then
        echo "✓ PV actualizado correctamente."
        [ -n "$PV_RESIZE_OUTPUT" ] && echo "$PV_RESIZE_OUTPUT"
      else
        echo "⚠ Advertencia al actualizar PV: $PV_RESIZE_OUTPUT"
      fi
      
      # Verificar espacio libre del VG después del pvresize
      echo "Verificando espacio disponible en VG..."
      VG_FREE=$(exec_in_vm "vgs --noheadings --units g -o vg_free $VG_NAME 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
      VG_SIZE=$(exec_in_vm "vgs --noheadings --units g -o vg_size $VG_NAME 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
      LV_SIZE=$(exec_in_vm "lvs --noheadings --units g -o lv_size $VG_NAME/$LV_NAME 2>/dev/null | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')
      
      echo "  VG total: ${VG_SIZE}G, VG libre: ${VG_FREE}G, LV actual: ${LV_SIZE}G"
      
      # Paso 2: Expandir el Logical Volume
      echo "Expandiendo Logical Volume..."
      
      # Intentar primero con +100%FREE
      LV_EXTEND_OUTPUT=$(exec_in_vm "lvextend -l +100%FREE $LV_PATH 2>&1" 2>/dev/null)
      LV_EXTEND_EXIT=$?
      
      # Si falla porque no hay espacio libre, intentar expandir al 100% del VG
      if [ $LV_EXTEND_EXIT -ne 0 ] && echo "$LV_EXTEND_OUTPUT" | grep -q "matches existing size"; then
        echo "  No hay espacio libre en VG, expandiendo al tamaño máximo del VG..."
        LV_EXTEND_OUTPUT=$(exec_in_vm "lvextend -l 100%VG $LV_PATH 2>&1" 2>/dev/null)
        LV_EXTEND_EXIT=$?
      fi
      
      # Si aún falla, intentar con tamaño específico basado en el espacio libre del VG
      if [ $LV_EXTEND_EXIT -ne 0 ] && [ -n "$VG_FREE" ] && [ "$VG_FREE" != "0" ]; then
        echo "  Intentando expandir con el espacio libre detectado..."
        LV_EXTEND_OUTPUT=$(exec_in_vm "lvextend -L +${VG_FREE}G $LV_PATH 2>&1" 2>/dev/null)
        LV_EXTEND_EXIT=$?
      fi
      
      if [ $LV_EXTEND_EXIT -eq 0 ]; then
        echo "✓ LV expandido correctamente."
        [ -n "$LV_EXTEND_OUTPUT" ] && echo "$LV_EXTEND_OUTPUT"
        
        # Paso 3: Expandir el filesystem
        echo "Expandiendo filesystem..."
        RESIZE2FS_OUTPUT=$(exec_in_vm "resize2fs $LV_PATH 2>&1" 2>/dev/null)
        RESIZE2FS_EXIT=$?
        
        if [ $RESIZE2FS_EXIT -eq 0 ]; then
          echo "✓ Filesystem expandido correctamente."
          [ -n "$RESIZE2FS_OUTPUT" ] && echo "$RESIZE2FS_OUTPUT"
        else
          echo "⚠ Error al expandir filesystem: $RESIZE2FS_OUTPUT"
        fi
      else
        echo "⚠ Error al expandir LV: $LV_EXTEND_OUTPUT"
        echo "Estado del VG:"
        exec_in_vm "vgs $VG_NAME && lvs $VG_NAME/$LV_NAME" 2>/dev/null
        echo ""
        echo "Comandos manuales:"
        echo "  pvresize $PV_NAME"
        echo "  lvextend -l 100%VG $LV_PATH"
        echo "  resize2fs $LV_PATH"
      fi
    else
      echo "⚠ No se pudo detectar VG/LV/PV usando comandos LVM."
      echo "  VG detectado: ${VG_NAME:-'N/A'}"
      echo "  LV detectado: ${LV_NAME:-'N/A'}"
      echo "  PV detectado: ${PV_NAME:-'N/A'}"
      echo "  Expande manualmente con: pvresize /dev/sdaX && lvextend -l +100%FREE /dev/vg/lv && resize2fs /dev/vg/lv"
    fi
    
    echo ""
    echo "Estado final del disco:"
    exec_in_vm "df -h /" 2>/dev/null || echo "No se pudo consultar el estado final."
  else
    echo "✗ Fallo al intentar redimensionar el disco en VM $VMID."
  fi
  
  echo "---------------------------------------------"
done

echo ""
echo "Proceso completado para todas las VMs."
