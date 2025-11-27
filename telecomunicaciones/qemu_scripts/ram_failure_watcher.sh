#!/bin/bash

VMID=$1
NODE=$(hostname)

# Validacion de argumento
if [ -z "$VMID" ]; then
  echo "Error: Falta el VM ID. Uso: $0 <vmid>"
  exit 1
fi

# 1. Buscar rastros de OOM Killer (Falta de RAM en el Host) o crasheos
# Usamos pvesh para traer el journal y grep para filtrar
echo "--- BUSCANDO ERRORES CRITICOS (OOM / Crash) EN JOURNAL PARA VM $VMID ---"
pvesh get /nodes/$NODE/journal --lastentries 1000 --output-format text | \
grep -iE "VM $VMID|kvm" | \
grep -iE "oom-killer|Out of memory|kill process|segfault"

if [ $? -ne 0 ]; then
    echo "No se encontraron eventos de 'Out of Memory' o crasheos recientes para la VM $VMID."
else
    echo "ATENCION: Se han encontrado coincidencias arriba. Revisa si el Host mato el proceso."
fi

echo ""
echo "--- ULTIMAS TAREAS REGISTRADAS EN PROXMOX PARA VM $VMID ---"
# 2. Ver historial de tareas de la VM (Start, Stop, Shutdown)
# Filtramos directamente con grep en la salida de texto
pvesh get /cluster/tasks --output-format text | grep -E "qmstart|qmstop|qmshutdown|qmreboot" | grep ":$VMID:" | head -n 10

echo ""
echo "Leyenda:"
echo "qmstop/shutdown = Apagado ordenado por usuario/API."
echo "Si la VM se apago y NO sale aqui, o sale como error, revisa la seccion de arriba (Journal)."