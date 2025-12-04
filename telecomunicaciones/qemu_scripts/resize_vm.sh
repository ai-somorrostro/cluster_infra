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
    echo "Consultando estado interno del disco (lsblk)..."
    echo ""
    
    # Ejecutar comando en la VM y limpiar JSON con Python inline
    qm guest exec $VMID -- lsblk -a 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin)['out-data'])" 2>/dev/null || echo "No se pudo consultar el estado del disco (puede requerir qemu-guest-agent)"
    
    echo ""
    echo "Si ves el tamaño actualizado arriba, entra en la VM y expande la particion."
  else
    echo "✗ Fallo al intentar redimensionar el disco en VM $VMID."
  fi
  
  echo "---------------------------------------------"
done

echo ""
echo "Proceso completado para todas las VMs."
