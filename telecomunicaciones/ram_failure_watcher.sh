#!/bin/bash

VMID=125
NODE=$(hostname)

# 1. Buscar rastros de OOM Killer (Falta de RAM en el Host) o crasheos
# Usamos pvesh para traer el journal y grep para filtrar
echo "--- BUSCANDO ERRORES CRITICOS (OOM / Crash) EN JOURNAL ---"
pvesh get /nodes/$NODE/journal --lastentries 1000 --output-format text | \
grep -iE "VM $VMID|kvm" | \
grep -iE "oom-killer|Out of memory|kill process|segfault"

if [ $? -ne 0 ]; then
    echo "No se encontraron eventos de 'Out of Memory' o crasheos recientes para la VM $VMID."
else
    echo "ATENCION: Se han encontrado coincidencias arriba. Revisa si el Host mato el proceso."
fi

echo ""
echo "--- ULTIMAS TAREAS REGISTRADAS EN PROXMOX ---"
# 2. Ver historial de tareas de la VM (Start, Stop, Shutdown)
pvesh get /cluster/tasks --vmid $VMID --limit 10 --output-format text | \
awk '{printf "%-20s %-10s %-10s %-20s\n", $2, $3, $5, $6}'

echo ""
echo "Leyenda:"
echo "qmstop/shutdown = Apagado ordenado por usuario/API."
echo "Si la VM se apago y NO sale aqui, o sale como error, revisa la seccion de arriba (Journal)."