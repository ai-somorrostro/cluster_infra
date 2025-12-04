#!/bin/bash

# Configuracion
VMID=$1
DISK="scsi0"
SIZE=$2

# Validacion de argumentos
if [ -z "$VMID" ] || [ -z "$SIZE" ]; then
  echo "Error: Faltan argumentos. Uso: $0 <vmid> <tamano>"
  echo "Ejemplo: $0 121 +20G"
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
  
  # 2. Ejecutar comando en la VM usando pvesh con el nodo correcto
  pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "lsblk" --arg "-a" 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('out-data', ''))" || echo "No se pudo ejecutar lsblk en la VM (puede requerir qemu-guest-agent)"
  
  echo "---------------------------------------------"
  echo "Si ves el tamaño actualizado arriba, entra en la VM y expande la particion."
else
  echo "Fallo al intentar redimensionar el disco."
  exit 1
fi