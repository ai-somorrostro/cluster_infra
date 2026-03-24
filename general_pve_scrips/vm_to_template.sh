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
NAME_EXACT=""
NAME_PREFIX=""
NAME_SUFFIX=""
SOURCE_STORAGE=""
TARGET_STORAGE=""

usage() {
  echo "Uso: $0 [--no-sysprep] [--force-stop] [--wait <segundos>] [--name <nuevo>] [--name-prefix <p>] [--name-suffix <s>] [--from <storage>] [--to <storage>] <vmid1> [vmid2] ..."
  echo ""
  echo "Opciones:"
  echo "  --no-sysprep     No hace limpieza dentro de la VM"
  echo "  --force-stop     Si no apaga en WAIT, hace stop duro"
  echo "  --wait N         Segundos a esperar a shutdown (default: $WAIT_SECONDS)"
  echo "  --name NUEVO     Renombra la VM/template a NUEVO (solo si pasas 1 VMID)"
  echo "  --name-prefix P  Renombra como P+<nombre_actual>"
  echo "  --name-suffix S  Renombra como <nombre_actual>+S"
  echo "  --from S         Mover discos que estén en este storage origen"
  echo "  --to S           Mover discos al storage destino (requiere --from)"
  echo ""
  echo "Ejemplos:"
  echo "  $0 --wait 240 120 121"
  echo "  $0 --name ubuntu-24-template 120"
  echo "  $0 --name-suffix -tpl 120 121"
  echo "  $0 --from local-lvm --to ssd-data 120"
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
    --name)
      NAME_EXACT="${2:-}"
      if [[ -z "$NAME_EXACT" ]]; then
        echo -e "${RED}Error:${NC} --name requiere un valor"
        exit 1
      fi
      shift 2
      ;;
    --name-prefix)
      NAME_PREFIX="${2:-}"
      if [[ -z "$NAME_PREFIX" ]]; then
        echo -e "${RED}Error:${NC} --name-prefix requiere un valor"
        exit 1
      fi
      shift 2
      ;;
    --name-suffix)
      NAME_SUFFIX="${2:-}"
      if [[ -z "$NAME_SUFFIX" ]]; then
        echo -e "${RED}Error:${NC} --name-suffix requiere un valor"
        exit 1
      fi
      shift 2
      ;;
    --wait)
      WAIT_SECONDS="${2:-}"
      if [[ -z "$WAIT_SECONDS" || ! "$WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error:${NC} --wait requiere un número"
        exit 1
      fi
      shift 2
      ;;
    --from)
      SOURCE_STORAGE="${2:-}"
      if [[ -z "$SOURCE_STORAGE" ]]; then
        echo -e "${RED}Error:${NC} --from requiere un valor"
        exit 1
      fi
      shift 2
      ;;
    --to)
      TARGET_STORAGE="${2:-}"
      if [[ -z "$TARGET_STORAGE" ]]; then
        echo -e "${RED}Error:${NC} --to requiere un valor"
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

if [[ -n "$TARGET_STORAGE" && -z "$SOURCE_STORAGE" ]]; then
  echo -e "${RED}Error:${NC} --to requiere también --from"
  exit 1
fi

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

VMIDS=("$@")

if [[ -n "$NAME_EXACT" && ${#VMIDS[@]} -ne 1 ]]; then
  echo -e "${RED}Error:${NC} --name solo se permite con 1 VMID (para varios usa --name-prefix/--name-suffix)"
  exit 1
fi

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

move_disks() {
  echo -e "${YELLOW}[*]${NC} Detectando discos en ${SOURCE_STORAGE}..."
  mapfile -t DISKS < <(qm config "$VMID" 2>/dev/null | grep -E '^(scsi|virtio|sata|ide)[0-9]+:' | grep -v 'media=cdrom')

  if [ ${#DISKS[@]} -eq 0 ]; then
    echo -e "${YELLOW}[!]${NC} No se encontraron discos"
    return 0
  fi

  for line in "${DISKS[@]}"; do
    local disk_key storage
    disk_key=$(echo "$line" | cut -d: -f1)
    storage=$(echo "$line" | cut -d: -f2 | xargs | cut -d: -f1)

    if [ "$storage" != "$SOURCE_STORAGE" ]; then
      echo -e "${YELLOW}[~]${NC} ${disk_key}: está en ${storage} (no es ${SOURCE_STORAGE}), saltando"
      continue
    fi

    echo -e "${YELLOW}[*]${NC} Moviendo ${disk_key}: ${SOURCE_STORAGE} → ${TARGET_STORAGE}"
    if qm move-disk "$VMID" "$disk_key" "$TARGET_STORAGE" --delete 1 2>&1 | while IFS= read -r l; do echo "    $l"; done; then
      echo -e "${GREEN}[✓]${NC} ${disk_key} movido a ${TARGET_STORAGE}"
    else
      echo -e "${RED}[✗]${NC} Falló mover ${disk_key}"
    fi
  done
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

maybe_rename_vm() {
  local target_name=""

  if [[ -n "$NAME_EXACT" ]]; then
    target_name="$NAME_EXACT"
  elif [[ -n "$NAME_PREFIX" || -n "$NAME_SUFFIX" ]]; then
    target_name="${NAME_PREFIX}${VM_NAME}${NAME_SUFFIX}"
  else
    return 0
  fi

  if [[ -z "$target_name" ]]; then
    return 0
  fi

  if [[ "$target_name" = "$VM_NAME" ]]; then
    return 0
  fi

  echo -e "${YELLOW}[*]${NC} Renombrando: ${VM_NAME} -> ${target_name}"
  if pvesh set /nodes/"$NODE"/qemu/"$VMID"/config --name "$target_name" >/dev/null 2>&1; then
    VM_NAME="$target_name"
    echo -e "${GREEN}[✓]${NC} Renombrado"
    return 0
  fi

  echo -e "${RED}[✗]${NC} No se pudo renombrar (¿nombre duplicado? ¿permisos?)"
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

  if ! maybe_rename_vm; then
    echo -e "${RED}[✗]${NC} Renombrado falló; no convierto esta VM"
    continue
  fi

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

  if [[ -n "$SOURCE_STORAGE" && -n "$TARGET_STORAGE" ]]; then
    move_disks
  fi
done

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}Completado${NC}"
echo -e "${GREEN}==========================================${NC}"
