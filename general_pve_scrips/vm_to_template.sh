#!/bin/bash

# vm_to_template.sh - Convierte una VM existente en template (Proxmox VE)

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DO_SYSPREP=1
FORCE_STOP=0
WAIT_SECONDS=180

usage() {
  echo "Uso: $0 [--no-sysprep] [--force-stop] [--wait <segundos>] <vmid1> [vmid2] ..."
  echo ""
  echo "Opciones:"
  echo "  --no-sysprep     No hace limpieza dentro de la VM"
  echo "  --force-stop     Si no apaga en WAIT, hace stop duro"
  echo "  --wait N         Segundos a esperar a shutdown (default: $WAIT_SECONDS)"
  echo ""
  echo "Ejemplo:"
  echo "  $0 --wait 240 120 121"
}

while [[ "${1:-}" =~ ^-- ]]; do
  case "${1:-}" in
    --sysprep)
      DO_SYSPREP=1
      shift 1
      ;;
    --no-sysprep)
      DO_SYSPREP=0
      shift 1
      ;;
    --force-stop)
      FORCE_STOP=1
      shift 1
      ;;
    --wait)
      WAIT_SECONDS="${2:-}"
      if [[ -z "$WAIT_SECONDS" || ! "$WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error:${NC} --wait requiere un número"
        exit 1
      fi
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}Opción desconocida:${NC} $1"
      usage
      exit 1
      ;;
  esac
done

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

VMIDS=("$@")

wait_for_pid() {
  local pid=$1
  local timeout=$2
  local count=0
  while [ $count -lt $timeout ]; do
    sleep 1
    local status
    status=$(pvesh get /nodes/"$NODE"/qemu/"$VMID"/agent/exec-status --pid "$pid" --output-format json 2>/dev/null || echo "")
    if echo "$status" | grep -q '"exited"'; then
      echo "$status"
      return 0
    fi
    count=$((count+1))
  done
  echo ""
  return 1
}

run_cmd() {
  local cmd_arr=("$@")
  local pvesh_args=""
  for arg in "${cmd_arr[@]}"; do
    local escaped_arg
    escaped_arg=$(echo "$arg" | sed 's/"/\\"/g')
    pvesh_args="$pvesh_args --command \"$escaped_arg\""
  done
  local out
  out=$(eval pvesh create /nodes/"$NODE"/qemu/"$VMID"/agent/exec $pvesh_args --output-format json 2>/dev/null || echo "")
  local pid
  pid=$(echo "$out" | grep -oP '"pid":\K[0-9]+' || true)
  if [ -z "$pid" ]; then return 1; fi
  local res
  res=$(wait_for_pid "$pid" 60 || true)
  local exitcode
  exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
  return "$exitcode"
}

detect_vm_node_and_name() {
  VM_INFO=$(pvesh get /cluster/resources --type vm --output-format json | \
    python3 -c "import sys, json; vms=json.load(sys.stdin); vm=next((i for i in vms if i.get('vmid')==int('$VMID')), None); print(f\"{vm.get('node','N/A')}|{vm.get('name','N/A')}|{vm.get('type','N/A')}\") if vm else print('N/A|N/A|N/A')")
  NODE=$(echo "$VM_INFO" | cut -d'|' -f1)
  VM_NAME=$(echo "$VM_INFO" | cut -d'|' -f2)
  VM_TYPE=$(echo "$VM_INFO" | cut -d'|' -f3)
}

get_vm_status_json() {
  pvesh get /nodes/"$NODE"/qemu/"$VMID"/status/current --output-format json 2>/dev/null || true
}

enable_agent_if_needed() {
  if [ "${AGENT_ENABLED:-0}" = "1" ]; then
    return 0
  fi

  echo -e "${YELLOW}[*]${NC} Agent deshabilitado en Proxmox; intentando habilitarlo..."
  if pvesh set /nodes/"$NODE"/qemu/"$VMID"/config --agent 1 >/dev/null 2>&1; then
    VM_STATUS=$(get_vm_status_json)
    AGENT_ENABLED=$(echo "$VM_STATUS" | grep -oP '"agent":\K[0-9]+' || echo "0")
    if [ "$AGENT_ENABLED" = "1" ]; then
      echo -e "${GREEN}[✓]${NC} Agent habilitado"
      return 0
    fi
  fi

  echo -e "${RED}[✗]${NC} No se pudo habilitar el agent (¿permisos? ¿VM sin config qemu-agent?)"
  return 1
}

shutdown_vm() {
  echo -e "${YELLOW}[*]${NC} Shutdown VM..."
  pvesh create /nodes/"$NODE"/qemu/"$VMID"/status/shutdown --timeout 10 >/dev/null 2>&1 || true

  local waited=0
  while [ $waited -lt "$WAIT_SECONDS" ]; do
    local st
    st=$(get_vm_status_json)
    if echo "$st" | grep -q '"status":"stopped"'; then
      echo -e "${GREEN}[✓]${NC} VM apagada"
      return 0
    fi
    sleep 2
    waited=$((waited+2))
  done

  if [ $FORCE_STOP -eq 1 ]; then
    echo -e "${YELLOW}[!]${NC} No apagó a tiempo, forzando stop..."
    pvesh create /nodes/"$NODE"/qemu/"$VMID"/status/stop >/dev/null 2>&1 || true
    sleep 2
    return 0
  fi

  echo -e "${RED}[✗]${NC} No apagó en ${WAIT_SECONDS}s (usa --force-stop si quieres stop duro)"
  return 1
}

sysprep_vm() {
  echo -e "${YELLOW}[*]${NC} Sysprep dentro de la VM (agent)..."

  # cosas típicas para templates: cloud-init clean, machine-id, ssh host keys
  # (si alguna no existe, no abortamos)
  run_cmd "sh" "-c" "command -v cloud-init >/dev/null 2>&1 && cloud-init clean --logs || true"
  run_cmd "sh" "-c" "truncate -s 0 /etc/machine-id || true"
  run_cmd "sh" "-c" "rm -f /var/lib/dbus/machine-id || true"
  run_cmd "sh" "-c" "ln -sf /etc/machine-id /var/lib/dbus/machine-id || true"
  run_cmd "sh" "-c" "rm -f /etc/ssh/ssh_host_* || true"
  run_cmd "sh" "-c" "find /var/log -type f -name '*.log' -exec truncate -s 0 {} + 2>/dev/null || true"
  run_cmd "sh" "-c" "rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null || true"

  echo -e "${GREEN}[✓]${NC} Sysprep completado"
}

convert_to_template() {
  echo -e "${YELLOW}[*]${NC} Convirtiendo a template..."
  if pvesh create /nodes/"$NODE"/qemu/"$VMID"/template >/dev/null 2>&1; then
    echo -e "${GREEN}[✓]${NC} VM $VMID convertida a template"
    return 0
  fi
  echo -e "${RED}[✗]${NC} Falló convertir a template (¿ya es template? ¿permisos? ¿VM corriendo?)"
  return 1
}

for VMID in "${VMIDS[@]}"; do
  if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}[✗]${NC} VMID inválido: $VMID"
    continue
  fi

  echo -e "\n${YELLOW}==========================================${NC}"
  echo "Detectando ubicación de la VM $VMID..."

  detect_vm_node_and_name
  if [ "$NODE" = "N/A" ] || [ -z "$NODE" ]; then
    echo -e "${RED}[✗]${NC} No se encuentra la VM $VMID en ningún nodo del cluster."
    continue
  fi
  if [ "$VM_TYPE" != "qemu" ]; then
    echo -e "${RED}[✗]${NC} VMID $VMID no es QEMU (type: $VM_TYPE). Este script es para qemu."
    continue
  fi

  echo "Nodo: $NODE | Nombre: $VM_NAME | VMID: $VMID"
  echo -e "${YELLOW}==========================================${NC}"

  VM_STATUS=$(get_vm_status_json)
  if [ -z "$VM_STATUS" ]; then
    echo -e "${RED}[✗]${NC} No se pudo obtener estado (¿existe? ¿nodo correcto?)"
    continue
  fi

  STATUS=$(echo "$VM_STATUS" | grep -oP '"status":"\K[^"]+' || echo "unknown")
  AGENT_ENABLED=$(echo "$VM_STATUS" | grep -oP '"agent":\K[0-9]+' || echo "0")

  if [ "$STATUS" = "running" ] && [ $DO_SYSPREP -eq 1 ]; then
    if enable_agent_if_needed; then
      if ! sysprep_vm; then
        echo -e "${RED}[✗]${NC} Sysprep falló; no convierto esta VM"
        continue
      fi
    else
      continue
    fi
  fi

  if [ "$STATUS" = "running" ]; then
    if ! shutdown_vm; then
      continue
    fi
  else
    echo -e "${YELLOW}[*]${NC} VM ya está parada (status: $STATUS)"
  fi

  if ! convert_to_template; then
    continue
  fi
done

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}Completado${NC}"
echo -e "${GREEN}==========================================${NC}"
