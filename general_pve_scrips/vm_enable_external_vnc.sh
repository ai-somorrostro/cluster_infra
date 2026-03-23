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
RESTART_ON_APPLY=1

usage() {
  echo "Uso: $0 [--bind <ip>] [--display <n>] [--display-base <n>] [--password <8chars>] [--expire <segundos>] <vmid1> [vmid2] ..."
  echo "Uso (modo por pares): $0 [flags] <vmid1> <puerto1> <vmid2> <puerto2> ..."
  echo ""
  echo "Notas:"
  echo "  - Esto añade/actualiza 'args: -vnc <bind>:<display>[,password=on]' en la config de la VM (persistente)."
  echo "  - La contraseña NO es persistente: si usas --password la setea solo si la VM está running ahora."
  echo "  - Puerto VNC = 5900 + display (ej: display 77 => TCP 5977)."
  echo "  - En modo por pares, el 'puerto' es ese TCP real (el script calcula display = puerto - 5900)."
  echo "  - En modo por pares no uses --display/--display-base (se calculan desde el puerto)."
  echo ""
  echo "Opciones:"
  echo "  --bind IP          Bind para VNC (default: $BIND_ADDR)"
  echo "  --display N        Display fijo (solo permitido si pasas 1 VMID)"
  echo "  --display-base N   Para múltiples VMIDs: display = base + (vmid % 100) (default: $DISPLAY_BASE)"
  echo "  --password PASS    Activa password=on y setea password (max 8 chars)"
  echo "  --expire SECS      Opcional: expire_password (requiere --password y VM running)"
  echo "  --no-restart        No reinicia la VM tras aplicar los args (si estaba running)"
  echo ""
  echo "Ejemplos:"
  echo "  $0 --display 77 --password foobar1 120"
  echo "  $0 --display-base 200 --bind 0.0.0.0 120 121 122"
  echo "  $0 --bind 192.168.136.238 120 5977 121 5978"
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
    --no-restart)
      RESTART_ON_APPLY=0
      shift 1
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

REST=("$@")

if [[ -n "$EXPIRE_SECONDS" && $PASSWORD_ON -ne 1 ]]; then
  echo -e "${RED}Error:${NC} --expire requiere --password"
  exit 1
fi

PAIR_MODE=0
if [ $(( ${#REST[@]} % 2 )) -eq 0 ] && [ ${#REST[@]} -ge 2 ]; then
  # Solo activamos modo por pares si los "puertos" parecen puertos VNC reales (>=5900).
  # Formato: vmid1 puerto1 vmid2 puerto2 ...
  PAIR_MODE=1
  for ((j=1; j<${#REST[@]}; j+=2)); do
    tok="${REST[$j]}"
    if [[ ! "$tok" =~ ^[0-9]+$ ]] || [ "$tok" -lt 5900 ]; then
      PAIR_MODE=0
      break
    fi
  done
fi

VMIDS=()
PORTS=()

if [ $PAIR_MODE -eq 1 ]; then
  for ((i=0; i<${#REST[@]}; i+=2)); do
    VMIDS+=("${REST[$i]}")
    PORTS+=("${REST[$((i+1))]}")
  done
else
  VMIDS=("${REST[@]}")
fi

if [[ -n "$DISPLAY" ]]; then
  if [ $PAIR_MODE -eq 1 ]; then
    echo -e "${RED}Error:${NC} En modo por pares, no uses --display (se calcula desde el puerto)."
    exit 1
  fi
  if [ ${#VMIDS[@]} -ne 1 ]; then
    echo -e "${RED}Error:${NC} --display solo se permite con 1 VMID (para varios usa --display-base o modo por pares)."
    exit 1
  fi
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
  # (por si qm config sacara más de una línea args:, las pegamos)
  qm config "$vmid" 2>/dev/null | sed -n 's/^args: //p' | tr '\n' ' ' || true
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

update_notes_vnc() {
  local vmid="$1"
  local bind="$2"
  local port="$3"
  local disp="$4"
  local password_on="$5"

  local vnc_line="VNC: ${bind}:${disp} → puerto ${port}$([ "$password_on" -eq 1 ] && echo " (password=on)" || echo "")"

  python3 - "$vmid" "$vnc_line" <<'PY'
import sys, subprocess, re

vmid = sys.argv[1]
vnc_line = sys.argv[2]

result = subprocess.run(["qm", "config", vmid], capture_output=True, text=True)
raw = ""
for line in result.stdout.splitlines():
    if line.startswith("description:"):
        raw = line[len("description:"):].strip()
        break

# Proxmox escapa los saltos de línea como literales \n
notes = raw.replace("\\n", "\n")

marker_start = "<!-- vnc-config -->"
marker_end   = "<!-- /vnc-config -->"
new_section  = f"{marker_start}\n{vnc_line}\n{marker_end}"

if marker_start in notes:
    notes = re.sub(
        re.escape(marker_start) + r".*?" + re.escape(marker_end),
        new_section,
        notes,
        flags=re.DOTALL
    )
else:
    notes = notes.rstrip("\n") + ("\n\n" if notes.strip() else "") + new_section

escaped = notes.replace("\n", "\\n")
subprocess.run(["qm", "set", vmid, "--description", escaped], check=True,
               capture_output=True)
PY
}

describe_current_vnc() {
  local existing="$1"
  # salida: "count|first_vnc_arg"
  python3 - "$existing" <<'PY'
import sys, shlex, re

existing = sys.argv[1] if len(sys.argv) > 1 else ""
tokens = shlex.split(existing) if existing.strip() else []

vnc_args = []
i = 0
while i < len(tokens):
    if tokens[i] == "-vnc" and i + 1 < len(tokens):
        vnc_args.append(tokens[i+1])
        i += 2
        continue
    i += 1

count = len(vnc_args)
first = vnc_args[0] if count else ""
print(f"{count}|{first}")
PY
}

for ((i=0; i<${#VMIDS[@]}; i++)); do
  VMID="${VMIDS[$i]}"
  if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}[✗]${NC} VMID inválido: $VMID"
    continue
  fi
  DISP=""
  VNC_PORT=""

  if [ $PAIR_MODE -eq 1 ]; then
    VNC_PORT="${PORTS[$i]}"
    if [[ -z "$VNC_PORT" || ! "$VNC_PORT" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}[✗]${NC} Puerto inválido para VMID $VMID: ${VNC_PORT}"
      continue
    fi
    if [ "$VNC_PORT" -lt 5900 ]; then
      echo -e "${RED}[✗]${NC} Puerto debe ser >= 5900 (donde port=5900+display). VMID: $VMID, puerto: $VNC_PORT"
      continue
    fi
    DISP=$((VNC_PORT - 5900))
  else
    DISP="$(display_for_vmid "$VMID")"
    VNC_PORT="$((5900 + DISP))"
  fi

  VNC_ARGS="-vnc ${BIND_ADDR}:${DISP}"
  if [ $PASSWORD_ON -eq 1 ]; then
    VNC_ARGS="${VNC_ARGS},password=on"
  fi

  echo -e "\n${YELLOW}==========================================${NC}"
  echo -e "${YELLOW}[*]${NC} VMID: $VMID"
  echo -e "${YELLOW}[*]${NC} args: ${VNC_ARGS}"
  echo -e "${YELLOW}[*]${NC} Puerto: ${VNC_PORT} (display ${DISP})"

  STATUS_BEFORE="$(vm_status "$VMID")"
  # Persistente: mergea args existentes + sustituye/añade -vnc
  CURRENT_ARGS="$(get_current_args "$VMID")"
  VNC_DESC="$(describe_current_vnc "$CURRENT_ARGS" || echo "0|")"
  VNC_COUNT="$(echo "$VNC_DESC" | cut -d'|' -f1)"
  VNC_OLD="$(echo "$VNC_DESC" | cut -d'|' -f2)"

  if [ "$VNC_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}[*]${NC} VNC ya estaba configurado (${VNC_COUNT} vez/veces). Antes: ${VNC_OLD}"
  else
    echo -e "${YELLOW}[*]${NC} No había VNC en args; lo vamos a añadir."
  fi
  MERGED_ARGS="$(merge_args_with_vnc "$CURRENT_ARGS" "$VNC_ARGS")"

  if qm set "$VMID" --args "$MERGED_ARGS" >/dev/null 2>&1; then
    echo -e "${GREEN}[✓]${NC} Config actualizada (VNC único: args -vnc sustituido)"
  else
    echo -e "${RED}[✗]${NC} Falló qm set --args (¿VM existe? ¿permisos?)"
    continue
  fi

  if update_notes_vnc "$VMID" "$BIND_ADDR" "$VNC_PORT" "$DISP" "$PASSWORD_ON" 2>/dev/null; then
    echo -e "${GREEN}[✓]${NC} Notes actualizado con config VNC"
  else
    echo -e "${YELLOW}[!]${NC} No se pudo actualizar Notes (no crítico)"
  fi

  # Aplicar la config VNC requiere reinicio (si está running).
  if [ $RESTART_ON_APPLY -eq 1 ] && [ "$STATUS_BEFORE" = "running" ]; then
    echo -e "${YELLOW}[*]${NC} Reiniciando VM para aplicar args VNC..."
    qm restart "$VMID" >/dev/null 2>&1 || true
  fi

  # No persistente: set_password (solo si la VM está running ahora)
  if [ $PASSWORD_ON -eq 1 ]; then
    STATUS="$(vm_status "$VMID")"
    if [ $RESTART_ON_APPLY -eq 1 ] && [ "$STATUS_BEFORE" = "running" ]; then
      # Tras restart puede tardar; damos un poco de margen.
      local wait_try=0
      while [ $wait_try -lt 30 ] && [ "$STATUS" != "running" ]; do
        sleep 2
        STATUS="$(vm_status "$VMID")"
        wait_try=$((wait_try+1))
      done
    fi
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
