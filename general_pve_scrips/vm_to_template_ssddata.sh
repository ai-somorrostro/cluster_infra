#!/bin/bash

# vm_to_template_ssddata.sh - Convierte una VM a template y mueve sus discos al storage indicado
# Ejecutar en el host Proxmox como root o con permisos de cluster.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DO_SYSPREP=1
FORCE_STOP=0
WAIT_SECONDS=180
SOURCE_STORAGE=""
TARGET_STORAGE=""

usage() {
  echo "Uso: $0 --from <storage> --to <storage> [--no-sysprep] [--force-stop] [--wait <segundos>] <vmid>"
  echo ""
  echo "Opciones:"
  echo "  --from S       Storage origen (requerido, ej: local-lvm, nvme-vms)"
  echo "  --to S         Storage destino (requerido, ej: ssd-data)"
  echo "  --no-sysprep   No limpia dentro de la VM antes de convertir"
  echo "  --force-stop   Si no apaga en --wait, hace stop duro"
  echo "  --wait N       Segundos a esperar a shutdown (default: $WAIT_SECONDS)"
  echo ""
  echo "Ejemplos:"
  echo "  $0 --from local-lvm --to ssd-data 120"
  echo "  $0 --from nvme-vms --to ssd-data --no-sysprep 120"
}

while [[ "${1:-}" =~ ^-- ]]; do
  case "${1:-}" in
    --from)
      SOURCE_STORAGE="${2:-}"
      if [[ -z "$SOURCE_STORAGE" ]]; then echo -e "${RED}Error:${NC} --from requiere un valor"; exit 1; fi
      shift 2 ;;
    --to)
      TARGET_STORAGE="${2:-}"
      if [[ -z "$TARGET_STORAGE" ]]; then echo -e "${RED}Error:${NC} --to requiere un valor"; exit 1; fi
      shift 2 ;;
    --no-sysprep) DO_SYSPREP=0; shift 1 ;;
    --force-stop) FORCE_STOP=1; shift 1 ;;
    --wait)
      WAIT_SECONDS="${2:-}"
      if [[ -z "$WAIT_SECONDS" || ! "$WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error:${NC} --wait requiere un número"; exit 1
      fi
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo -e "${RED}Opción desconocida:${NC} $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$SOURCE_STORAGE" ]]; then
  echo -e "${RED}Error:${NC} --from es obligatorio"; usage; exit 1
fi
if [[ -z "$TARGET_STORAGE" ]]; then
  echo -e "${RED}Error:${NC} --to es obligatorio"; usage; exit 1
fi

if [ $# -ne 1 ]; then usage; exit 1; fi
VMID="$1"

if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}Error:${NC} VMID inválido: $VMID"; exit 1
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

wait_for_agent_pid() {
  local pid=$1 timeout=$2 count=0
  while [ $count -lt $timeout ]; do
    sleep 1
    local status
    status=$(pvesh get /nodes/"$NODE"/qemu/"$VMID"/agent/exec-status --pid "$pid" --output-format json 2>/dev/null || echo "")
    if echo "$status" | grep -q '"exited"'; then echo "$status"; return 0; fi
    count=$((count+1))
  done
  echo ""; return 1
}

run_cmd() {
  local pvesh_args=""
  for arg in "$@"; do
    local e; e=$(echo "$arg" | sed 's/"/\\"/g')
    pvesh_args="$pvesh_args --command \"$e\""
  done
  local out; out=$(eval pvesh create /nodes/"$NODE"/qemu/"$VMID"/agent/exec $pvesh_args --output-format json 2>/dev/null || echo "")
  local pid; pid=$(echo "$out" | grep -oP '"pid":\K[0-9]+' || true)
  [ -z "$pid" ] && return 1
  local res; res=$(wait_for_agent_pid "$pid" 60 || true)
  local exitcode; exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
  return "$exitcode"
}

get_status_json() {
  pvesh get /nodes/"$NODE"/qemu/"$VMID"/status/current --output-format json 2>/dev/null || true
}

sysprep_vm() {
  echo -e "${YELLOW}[*]${NC} Sysprep dentro de la VM..."
  run_cmd "sh" "-c" "command -v cloud-init >/dev/null 2>&1 && cloud-init clean --logs || true"
  run_cmd "sh" "-c" "truncate -s 0 /etc/machine-id || true"
  run_cmd "sh" "-c" "rm -f /var/lib/dbus/machine-id || true"
  run_cmd "sh" "-c" "ln -sf /etc/machine-id /var/lib/dbus/machine-id || true"
  run_cmd "sh" "-c" "rm -f /etc/ssh/ssh_host_* || true"
  run_cmd "sh" "-c" "find /var/log -type f -name '*.log' -exec truncate -s 0 {} + 2>/dev/null || true"
  run_cmd "sh" "-c" "rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null || true"
  echo -e "${GREEN}[✓]${NC} Sysprep completado"
}

shutdown_vm() {
  echo -e "${YELLOW}[*]${NC} Apagando VM..."
  pvesh create /nodes/"$NODE"/qemu/"$VMID"/status/shutdown --timeout 10 >/dev/null 2>&1 || true
  local waited=0
  while [ $waited -lt "$WAIT_SECONDS" ]; do
    local st; st=$(get_status_json)
    if echo "$st" | grep -q '"status":"stopped"'; then
      echo -e "${GREEN}[✓]${NC} VM apagada"; return 0
    fi
    sleep 2; waited=$((waited+2))
  done
  if [ $FORCE_STOP -eq 1 ]; then
    echo -e "${YELLOW}[!]${NC} Timeout — forzando stop..."
    pvesh create /nodes/"$NODE"/qemu/"$VMID"/status/stop >/dev/null 2>&1 || true
    sleep 2; return 0
  fi
  echo -e "${RED}[✗]${NC} No apagó en ${WAIT_SECONDS}s (usa --force-stop para stop duro)"
  return 1
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo -e "\n${YELLOW}==========================================${NC}"
echo "VMID: $VMID"

VM_INFO=$(pvesh get /cluster/resources --type vm --output-format json | \
  python3 -c "import sys,json; vms=json.load(sys.stdin); vm=next((i for i in vms if i.get('vmid')==int('$VMID')),None); print(f\"{vm.get('node','N/A')}|{vm.get('name','N/A')}|{vm.get('type','N/A')}\") if vm else print('N/A|N/A|N/A')")
NODE=$(echo "$VM_INFO" | cut -d'|' -f1)
VM_NAME=$(echo "$VM_INFO" | cut -d'|' -f2)
VM_TYPE=$(echo "$VM_INFO" | cut -d'|' -f3)

if [ "$NODE" = "N/A" ] || [ -z "$NODE" ]; then
  echo -e "${RED}[✗]${NC} VM $VMID no encontrada en el cluster"; exit 1
fi
if [ "$VM_TYPE" != "qemu" ]; then
  echo -e "${RED}[✗]${NC} VMID $VMID no es QEMU (type: $VM_TYPE)"; exit 1
fi

echo "Nodo: $NODE | Nombre: $VM_NAME"
echo -e "${YELLOW}==========================================${NC}"

STATUS_JSON=$(get_status_json)
STATUS=$(echo "$STATUS_JSON" | grep -oP '"status":"\K[^"]+' || echo "unknown")
AGENT_ENABLED=$(echo "$STATUS_JSON" | grep -oP '"agent":\K[0-9]+' || echo "0")

# Sysprep
if [ "$STATUS" = "running" ] && [ $DO_SYSPREP -eq 1 ]; then
  if [ "$AGENT_ENABLED" = "1" ]; then
    sysprep_vm || { echo -e "${RED}[✗]${NC} Sysprep falló"; exit 1; }
  else
    echo -e "${YELLOW}[!]${NC} Agent no disponible — saltando sysprep"
  fi
fi

# Apagar
if [ "$STATUS" = "running" ]; then
  shutdown_vm || exit 1
else
  echo -e "${YELLOW}[*]${NC} VM ya está parada (status: $STATUS)"
fi

# Convertir a template
echo -e "${YELLOW}[*]${NC} Convirtiendo a template..."
if pvesh create /nodes/"$NODE"/qemu/"$VMID"/template >/dev/null 2>&1; then
  echo -e "${GREEN}[✓]${NC} Convertida a template"
else
  echo -e "${RED}[✗]${NC} Falló convertir a template (¿ya es template? ¿permisos?)"; exit 1
fi

# Mover discos
echo -e "${YELLOW}[*]${NC} Detectando discos..."
mapfile -t DISKS < <(qm config "$VMID" 2>/dev/null | grep -E '^(scsi|virtio|sata|ide)[0-9]+:' | grep -v 'media=cdrom')

if [ ${#DISKS[@]} -eq 0 ]; then
  echo -e "${YELLOW}[!]${NC} No se encontraron discos"; exit 0
fi

for line in "${DISKS[@]}"; do
  DISK_KEY=$(echo "$line" | cut -d: -f1)
  STORAGE=$(echo "$line" | cut -d: -f2 | xargs | cut -d: -f1)

  if [ "$STORAGE" != "$SOURCE_STORAGE" ]; then
    echo -e "${YELLOW}[~]${NC} ${DISK_KEY}: está en ${STORAGE} (no es ${SOURCE_STORAGE}), saltando"
    continue
  fi

  echo -e "${YELLOW}[*]${NC} Moviendo ${DISK_KEY}: ${SOURCE_STORAGE} → ${TARGET_STORAGE}"
  if qm move-disk "$VMID" "$DISK_KEY" "$TARGET_STORAGE" --delete 1 2>&1 | while IFS= read -r l; do echo "    $l"; done; then
    echo -e "${GREEN}[✓]${NC} ${DISK_KEY} movido a ${TARGET_STORAGE}"
  else
    echo -e "${RED}[✗]${NC} Falló mover ${DISK_KEY}"
  fi
done

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}Completado${NC}"
echo -e "${GREEN}==========================================${NC}"
