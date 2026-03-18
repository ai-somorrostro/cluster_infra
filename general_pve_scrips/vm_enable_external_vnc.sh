#!/bin/bash

# vm_enable_external_vnc.sh - Habilita VNC externo (RealVNC/TightVNC/Remmina) en VMs Proxmox
# Fuente: https://pve.proxmox.com/wiki/VNC_Client_Access

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

BIND_ADDR="0.0.0.0"
DISPLAY=""
DISPLAY_BASE=70
PASSWORD=""
EXPIRE_SECONDS=""
PASSWORD_ON=0

usage() {
  echo "Uso: $0 [--bind <ip>] [--display <n>] [--display-base <n>] [--password <8chars>] [--expire <segundos>] <vmid1> [vmid2] ..."
  echo ""
  echo "Notas:"
  echo "  - Esto añade/actualiza 'args: -vnc <bind>:<display>[,password=on]' en la config de la VM (persistente)."
  echo "  - La contraseña NO es persistente: si usas --password la setea solo si la VM está running ahora."
  echo "  - Puerto VNC = 5900 + display (ej: display 77 => TCP 5977)."
  echo ""
  echo "Opciones:"
  echo "  --bind IP          Bind para VNC (default: $BIND_ADDR)"
  echo "  --display N        Display fijo (solo permitido si pasas 1 VMID)"
  echo "  --display-base N   Para múltiples VMIDs: display = base + (vmid % 100) (default: $DISPLAY_BASE)"
  echo "  --password PASS    Activa password=on y setea password (max 8 chars)"
  echo "  --expire SECS      Opcional: expire_password (requiere --password y VM running)"
  echo ""
  echo "Ejemplos:"
  echo "  $0 --display 77 --password foobar1 120"
  echo "  $0 --display-base 200 --bind 0.0.0.0 120 121 122"
}

while [[ "${1:-}" =~ ^-- ]]; do
  case "${1:-}" in
    --bind)
      BIND_ADDR="${2:-}"
      if [[ -z "$BIND_ADDR" ]]; then
        echo -e "${RED}Error:${NC} --bind requiere un valor"
        exit 1
      fi
      shift 2
      ;;
    --display)
      DISPLAY="${2:-}"
      if [[ -z "$DISPLAY" || ! "$DISPLAY" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error:${NC} --display requiere un número"
        exit 1
      fi
      shift 2
      ;;
    --display-base)
      DISPLAY_BASE="${2:-}"
      if [[ -z "$DISPLAY_BASE" || ! "$DISPLAY_BASE" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error:${NC} --display-base requiere un número"
        exit 1
      fi
      shift 2
      ;;
    --password)
      PASSWORD="${2:-}"
      if [[ -z "$PASSWORD" ]]; then
        echo -e "${RED}Error:${NC} --password requiere un valor"
        exit 1
      fi
      if [ ${#PASSWORD} -gt 8 ]; then
        echo -e "${RED}Error:${NC} VNC password máximo 8 caracteres"
        exit 1
      fi
      PASSWORD_ON=1
      shift 2
      ;;
    --expire)
      EXPIRE_SECONDS="${2:-}"
      if [[ -z "$EXPIRE_SECONDS" || ! "$EXPIRE_SECONDS" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error:${NC} --expire requiere un número (segundos)"
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

if [[ -n "$DISPLAY" && ${#VMIDS[@]} -ne 1 ]]; then
  echo -e "${RED}Error:${NC} --display solo se permite con 1 VMID (para varios usa --display-base)"
  exit 1
fi

if [[ -n "$EXPIRE_SECONDS" && $PASSWORD_ON -ne 1 ]]; then
  echo -e "${RED}Error:${NC} --expire requiere --password"
  exit 1
fi

display_for_vmid() {
  local vmid="$1"
  if [[ -n "$DISPLAY" ]]; then
    echo "$DISPLAY"
    return 0
  fi
  echo $((DISPLAY_BASE + (vmid % 100)))
}

vm_status() {
  local vmid="$1"
  pvesh get /cluster/resources --type vm --output-format json | \
    python3 -c "import sys, json; vmid=int('$vmid'); vms=json.load(sys.stdin); vm=next((i for i in vms if i.get('vmid')==vmid), None); print(vm.get('status','unknown') if vm else 'unknown')"
}

get_current_args() {
  local vmid="$1"
  # línea tipo: args: -foo bar -vnc 0.0.0.0:77
  local line
  line="$(qm config "$vmid" 2>/dev/null | sed -n 's/^args: //p' | head -n 1 || true)"
  echo "$line"
}

merge_args_with_vnc() {
  local existing="$1"
  local vnc_args="$2" # "-vnc x:y[,password=on]"

  # Usa python/shlex para quitar cualquier -vnc previo sin cargarte el resto de args
  python3 - "$existing" "$vnc_args" <<'PY'
import sys, shlex

existing = sys.argv[1] if len(sys.argv) > 1 else ""
vnc_args = sys.argv[2] if len(sys.argv) > 2 else ""

tokens = shlex.split(existing) if existing.strip() else []

out = []
i = 0
while i < len(tokens):
    t = tokens[i]
    if t == "-vnc":
        # saltar "-vnc" y su argumento si existe
        i += 2
        continue
    out.append(t)
    i += 1

vnc_tokens = shlex.split(vnc_args)
out.extend(vnc_tokens)

try:
    joined = shlex.join(out)
except AttributeError:
    joined = " ".join(shlex.quote(x) for x in out)

print(joined)
PY
}

for VMID in "${VMIDS[@]}"; do
  if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}[✗]${NC} VMID inválido: $VMID"
    continue
  fi

  DISP="$(display_for_vmid "$VMID")"
  VNC_ARGS="-vnc ${BIND_ADDR}:${DISP}"
  if [ $PASSWORD_ON -eq 1 ]; then
    VNC_ARGS="${VNC_ARGS},password=on"
  fi

  echo -e "\n${YELLOW}==========================================${NC}"
  echo -e "${YELLOW}[*]${NC} VMID: $VMID"
  echo -e "${YELLOW}[*]${NC} args: ${VNC_ARGS}"
  echo -e "${YELLOW}[*]${NC} Puerto: $((5900 + DISP)) (display ${DISP})"

  # Persistente: mergea args existentes + sustituye/añade -vnc
  CURRENT_ARGS="$(get_current_args "$VMID")"
  MERGED_ARGS="$(merge_args_with_vnc "$CURRENT_ARGS" "$VNC_ARGS")"

  if qm set "$VMID" --args "$MERGED_ARGS" >/dev/null 2>&1; then
    echo -e "${GREEN}[✓]${NC} Config actualizada (args merge)"
  else
    echo -e "${RED}[✗]${NC} Falló qm set --args (¿VM existe? ¿permisos?)"
    continue
  fi

  # No persistente: set_password (solo si la VM está running ahora)
  if [ $PASSWORD_ON -eq 1 ]; then
    STATUS="$(vm_status "$VMID")"
    if [ "$STATUS" = "running" ]; then
      if qm monitor "$VMID" --cmd "set_password vnc $PASSWORD -d vnc2" >/dev/null 2>&1; then
        echo -e "${GREEN}[✓]${NC} Password seteada (no persistente)"
      else
        echo -e "${RED}[✗]${NC} Falló set_password vía qm monitor"
      fi

      if [[ -n "$EXPIRE_SECONDS" ]]; then
        if qm monitor "$VMID" --cmd "expire_password vnc +${EXPIRE_SECONDS} -d vnc2" >/dev/null 2>&1; then
          echo -e "${GREEN}[✓]${NC} Password expira en ${EXPIRE_SECONDS}s (no desconecta sesiones activas)"
        else
          echo -e "${RED}[✗]${NC} Falló expire_password vía qm monitor"
        fi
      fi
    else
      echo -e "${YELLOW}[!]${NC} VM no está running (status: $STATUS)."
      echo -e "${YELLOW}[!]${NC} La config quedó puesta, pero la password se setea tras arrancar (qm monitor)."
    fi
  fi
done

echo -e "\n${GREEN}==========================================${NC}"
echo -e "${GREEN}Completado${NC}"
echo -e "${GREEN}==========================================${NC}"
