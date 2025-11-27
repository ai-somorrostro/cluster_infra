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
# Corregido: pvesh no acepta --vmid ni --limit, hay que filtrar manualmente
pvesh get /cluster/tasks --output-format json-pretty | \
python3 -c "
import sys, json
tasks = json.load(sys.stdin)['data']
# Filtrar por VMID
vm_tasks = [t for t in tasks if str(t.get('id', '')).endswith(':$VMID:') or str(t.get('upid', '')).find(':$VMID:') != -1]
# Ordenar por starttime descendente y tomar los ultimos 10
vm_tasks.sort(key=lambda x: x.get('starttime', 0), reverse=True)
for task in vm_tasks[:10]:
    print(f\"{task.get('starttime', 'N/A'):<20} {task.get('type', 'N/A'):<15} {task.get('status', 'N/A'):<10} {task.get('user', 'N/A'):<20}\")
"

echo ""
echo "Leyenda:"
echo "qmstop/shutdown = Apagado ordenado por usuario/API."
echo "Si la VM se apago y NO sale aqui, o sale como error, revisa la seccion de arriba (Journal)."