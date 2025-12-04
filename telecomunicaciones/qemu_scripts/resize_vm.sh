#!/bin/bash

# Configuracion
VMID=125
DISK="scsi0"
SIZE=$1

# Validacion de argumento
if [ -z "$SIZE" ]; then
  echo "Error: Falta el tamano. Uso: $0 +10G"
  exit 1
fi

# DETECCION AUTOMATICA DEL NODO
# Obtenemos recursos del cluster -> buscamos el vmid -> extraemos el nodo
NODE=$(pvesh get /cluster/resources --type vm --output-format json | python3 -c "import sys, json; print(next((i['node'] for i in json.load(sys.stdin) if i.get('vmid') == $VMID), ''))")

if [ -z "$NODE" ]; then
  echo "Error: No se encuentra la VM $VMID en ningun nodo del cluster."
  exit 1
fi

echo "VM $VMID encontrada en nodo: $NODE"
echo "Redimensionando $DISK ($SIZE)..."

# 1. Ejecutar redimensionado en Proxmox apuntando al nodo correcto
pvesh set /nodes/$NODE/qemu/$VMID/resize --disk $DISK --size $SIZE

if [ $? -eq 0 ]; then
  echo "Resize correcto en el hipervisor."
  echo "Consultando estado interno del disco (lsblk)..."
  echo "---------------------------------------------"
  
  # 2. Ejecutar comando en la VM
  qm guest exec $VMID -- lsblk -a | python3 -c "import sys, json; print(json.load(sys.stdin)['out-data'])"
  
  echo "---------------------------------------------"
  echo "Si ves el tamaño actualizado arriba, entra en la VM y expande la particion."
else
  echo "Fallo al intentar redimensionar el disco."
  exit 1
fi