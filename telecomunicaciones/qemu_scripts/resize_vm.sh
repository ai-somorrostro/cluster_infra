#!/bin/bash

# Configuracion
DISK="scsi0"  # Hardcodeado
NODE=$(hostname)
VM_IDS=$1
SIZE=$2

# Validacion de argumentos
if [ -z "$VM_IDS" ] || [ -z "$SIZE" ]; then
  echo "Error: Faltan argumentos. Uso: $0 'vm_id1 vm_id2 vm_id3' +10G"
  exit 1
fi

# Convertir VM_IDS en array
IFS=' ' read -ra VMS <<< "$VM_IDS"

echo "Redimensionando $DISK en ${#VMS[@]} VM(s) en el nodo $NODE con tamano $SIZE..."
echo "=============================================="

# Iterar sobre cada VM
for VMID in "${VMS[@]}"; do
  echo ""
  echo "Procesando VM $VMID..."
  echo "---------------------------------------------"
  
  # Ejecutar redimensionado en Proxmox
  pvesh set /nodes/$NODE/qemu/$VMID/resize --disk $DISK --size $SIZE
  
  if [ $? -eq 0 ]; then
    echo "✓ Resize correcto en el hipervisor para VM $VMID."
    echo "Consultando estado interno del disco (lsblk)..."
    echo ""
    
    # Ejecutar comando en la VM y limpiar JSON con Python inline
    qm guest exec $VMID -- lsblk -a | python3 -c "import sys, json; print(json.load(sys.stdin)['out-data'])"
    
    echo ""
    echo "Si ves el tamaño actualizado arriba, entra en la VM y expande la particion."
  else
    echo "✗ Fallo al intentar redimensionar el disco en VM $VMID."
  fi
  
  echo "---------------------------------------------"
done

echo ""
echo "Proceso completado para todas las VMs."