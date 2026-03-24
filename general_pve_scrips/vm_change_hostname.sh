#!/bin/bash

# vm_change_hostname.sh - Cambia el hostname de una o varias VMs

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAME_EXACT=""
NAME_PREFIX=""
NAME_SUFFIX=""

usage() {
  echo "Uso:"
  echo "  $0 <vmid> <hostname>                          # una VM"
  echo "  $0 <vmid1> <hostname1> <vmid2> <hostname2>   # varias VMs con nombres explícitos"
  echo "  $0 --name-prefix <p> <vmid1> [vmid2] ...     # prefijo sobre hostname actual"
  echo "  $0 --name-suffix <s> <vmid1> [vmid2] ...     # sufijo sobre hostname actual"
  echo ""
  echo "Opciones:"
  echo "  --name-prefix P  Nuevo hostname = P + hostname_actual"
  echo "  --name-suffix S  Nuevo hostname = hostname_actual + S"
  echo ""
  echo "Ejemplos:"
  echo "  $0 100 webserver01"
  echo "  $0 100 webserver01 101 webserver02 102 webserver03"
  echo "  $0 --name-prefix prod- 100 101 102"
  echo "  $0 --name-suffix -dev 100 101"
}

while [[ "${1:-}" =~ ^-- ]]; do
  case "${1:-}" in
    --name-prefix)
      NAME_PREFIX="${2:-}"
      if [[ -z "$NAME_PREFIX" ]]; then echo -e "${RED}Error:${NC} --name-prefix requiere un valor"; exit 1; fi
      shift 2 ;;
    --name-suffix)
      NAME_SUFFIX="${2:-}"
      if [[ -z "$NAME_SUFFIX" ]]; then echo -e "${RED}Error:${NC} --name-suffix requiere un valor"; exit 1; fi
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo -e "${RED}Opción desconocida:${NC} $1"; usage; exit 1 ;;
  esac
done

if [ $# -lt 1 ]; then usage; exit 1; fi

# Construir lista de pares VMID→HOSTNAME
declare -a VMIDS=()
declare -A HOSTNAMES=()

USE_PREFIX_SUFFIX=0
if [[ -n "$NAME_PREFIX" || -n "$NAME_SUFFIX" ]]; then
  USE_PREFIX_SUFFIX=1
  VMIDS=("$@")
else
  # Modo pares: vmid1 hostname1 vmid2 hostname2 ...
  if (( $# % 2 != 0 )); then
    echo -e "${RED}Error:${NC} Se esperan pares vmid hostname (número par de argumentos)"
    usage; exit 1
  fi
  while [[ $# -gt 0 ]]; do
    VMIDS+=("$1")
    HOSTNAMES["$1"]="$2"
    shift 2
  done
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

wait_for_pid() {
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
  local res; res=$(wait_for_pid "$pid" 30 || true)
  local exitcode; exitcode=$(echo "$res" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
  return "$exitcode"
}

get_current_hostname() {
  local pid
  pid=$(pvesh create /nodes/"$NODE"/qemu/"$VMID"/agent/exec --command "hostname" --output-format json 2>/dev/null | grep -oP '"pid":\K[0-9]+' || true)
  [ -z "$pid" ] && echo "desconocido" && return
  sleep 1
  pvesh get /nodes/"$NODE"/qemu/"$VMID"/agent/exec-status --pid "$pid" --output-format json 2>/dev/null \
    | grep -oP '"out-data":"[^"]+' | cut -d'"' -f3 | base64 -d 2>/dev/null | tr -d '\n' || echo "desconocido"
}

# ─── Bucle principal ──────────────────────────────────────────────────────────

for VMID in "${VMIDS[@]}"; do
  if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}[✗]${NC} VMID inválido: $VMID"; continue
  fi

  echo -e "\n${YELLOW}==========================================${NC}"
  echo "Detectando ubicación de la VM $VMID..."

  VM_INFO=$(pvesh get /cluster/resources --type vm --output-format json | \
    python3 -c "import sys,json; vms=json.load(sys.stdin); vm=next((i for i in vms if i.get('vmid')==int('$VMID')),None); print(f\"{vm.get('node','N/A')}|{vm.get('name','N/A')}\") if vm else print('N/A|N/A')")
  NODE=$(echo "$VM_INFO" | cut -d'|' -f1)
  VM_NAME=$(echo "$VM_INFO" | cut -d'|' -f2)

  if [ "$NODE" = "N/A" ] || [ -z "$NODE" ]; then
    echo -e "${RED}[✗]${NC} VM $VMID no encontrada en el cluster"; continue
  fi

  echo "Nodo: $NODE | Nombre: $VM_NAME | VMID: $VMID"
  echo -e "${YELLOW}==========================================${NC}"

  # Verificar estado y agent
  VM_STATUS=$(pvesh get /nodes/"$NODE"/qemu/"$VMID"/status/current --output-format json 2>/dev/null || true)
  if ! echo "$VM_STATUS" | grep -q '"status":"running"' || ! echo "$VM_STATUS" | grep -q '"agent":1'; then
    echo -e "${RED}[✗]${NC} VM no está running o el agent no está activo"; continue
  fi

  # Obtener hostname actual
  echo -n "Hostname actual... "
  CURRENT_HOSTNAME=$(get_current_hostname)
  echo -e "${YELLOW}${CURRENT_HOSTNAME}${NC}"

  # Calcular nuevo hostname
  if [ $USE_PREFIX_SUFFIX -eq 1 ]; then
    NEW_HOSTNAME="${NAME_PREFIX}${CURRENT_HOSTNAME}${NAME_SUFFIX}"
  else
    NEW_HOSTNAME="${HOSTNAMES[$VMID]}"
  fi

  if [ "$CURRENT_HOSTNAME" = "$NEW_HOSTNAME" ]; then
    echo -e "${YELLOW}[!]${NC} Ya es '$NEW_HOSTNAME', nada que hacer"; continue
  fi

  echo -e "\n${YELLOW}Cambiando hostname a: $NEW_HOSTNAME${NC}\n"

  echo -n "Aplicando (hostnamectl)... "
  if run_cmd "hostnamectl" "set-hostname" "$NEW_HOSTNAME"; then
    echo -e "${GREEN}[OK]${NC}"
  else
    echo -e "${RED}[ERROR]${NC}"; continue
  fi

  echo -n "Backup /etc/hostname... "
  run_cmd "cp" "/etc/hostname" "/etc/hostname.bak" && echo -e "${GREEN}[OK]${NC}" || echo -e "${YELLOW}[WARN]${NC}"

  echo -n "Actualizando /etc/hostname... "
  run_cmd "sh" "-c" "echo '$NEW_HOSTNAME' > /etc/hostname" && echo -e "${GREEN}[OK]${NC}" || echo -e "${RED}[ERROR]${NC}"

  echo -n "Backup /etc/hosts... "
  run_cmd "cp" "/etc/hosts" "/etc/hosts.bak" && echo -e "${GREEN}[OK]${NC}" || echo -e "${YELLOW}[WARN]${NC}"

  echo -n "Actualizando /etc/hosts... "
  run_cmd "sh" "-c" "sed -i 's/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/' /etc/hosts && grep -q '127.0.1.1' /etc/hosts || echo '127.0.1.1\t$NEW_HOSTNAME' >> /etc/hosts" \
    && echo -e "${GREEN}[OK]${NC}" || echo -e "${YELLOW}[WARN]${NC}"

  # Verificar
  echo -n "Verificando... "
  VERIFIED=$(get_current_hostname)
  if [ "$VERIFIED" = "$NEW_HOSTNAME" ]; then
    echo -e "${GREEN}[OK] — ${VERIFIED}${NC}"
  else
    echo -e "${YELLOW}[WARN] — ${VERIFIED}${NC}"
  fi

  echo -e "${GREEN}Hostname: '${CURRENT_HOSTNAME}' → '${NEW_HOSTNAME}'${NC}"

  # Reiniciar
  echo -n "Reiniciando VM... "
  if pvesh create /nodes/"$NODE"/qemu/"$VMID"/status/reboot >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC}"
  else
    echo -e "${RED}[ERROR]${NC}"
  fi
done

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}Completado${NC}"
echo -e "${GREEN}==========================================${NC}"
