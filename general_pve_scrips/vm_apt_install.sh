#!/usr/bin/env bash

# vm_apt_install.sh - Instala paquetes apt en VMs usando la API de Proxmox.
# Puede ejecutarse desde un contenedor provisioner; no requiere pvesh/qm locales.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DOCKER=0
VMIDS=()
PACKAGES=()

usage() {
  echo "Uso: $0 [--with-docker] <vmid1> [vmid2] ... -- <paquete1> [paquete2] ..."
  echo "Ejemplo: $0 100 101 102 -- vim curl htop"
  echo "Ejemplo: $0 --with-docker 100 -- vim curl htop"
  echo ""
  echo "Credenciales:"
  echo "  export PROXMOX_API_URL=https://pve:8006/api2/json"
  echo "  export PROXMOX_API_TOKEN_ID='root@pam!infra'"
  echo "  export PROXMOX_API_TOKEN_SECRET='...'"
  echo ""
  echo "También puedes usar VARS_FILE=variables.pkrvars.hcl como fallback."
}

shell_join() {
  python3 - "$@" <<'PY'
import shlex
import sys

try:
    print(shlex.join(sys.argv[1:]))
except AttributeError:
    print(" ".join(shlex.quote(arg) for arg in sys.argv[1:]))
PY
}

parse_args() {
  case "${1:-}" in
    --help|-h)
      usage
      exit 0
      ;;
  esac

  if [ $# -lt 3 ]; then
    usage
    exit 1
  fi

  if [ "${1:-}" = "--with-docker" ]; then
    INSTALL_DOCKER=1
    shift
  fi

  local parsing_vmids=1
  for arg in "$@"; do
    if [ "$arg" = "--" ]; then
      parsing_vmids=0
      continue
    fi

    if [ "$parsing_vmids" -eq 1 ]; then
      VMIDS+=("$arg")
    else
      PACKAGES+=("$arg")
    fi
  done

  if [ ${#VMIDS[@]} -eq 0 ]; then
    echo -e "${RED}Error:${NC} Debes especificar al menos un VMID" >&2
    exit 1
  fi

  if [ ${#PACKAGES[@]} -eq 0 ]; then
    echo -e "${RED}Error:${NC} Debes especificar al menos un paquete" >&2
    exit 1
  fi
}

guest_run() {
  local timeout="$1"
  shift

  local result
  if result="$(pve_guest_exec_wait "$NODE" "$VMID" "$timeout" "$@")"; then
    [ -z "$result" ] || pve_guest_exec_output <<<"$result"
    return 0
  fi

  local rc=$?
  [ -z "$result" ] || pve_guest_exec_output <<<"$result"
  return "$rc"
}

guest_run_quiet() {
  guest_run "$@" >/dev/null 2>&1
}

vm_status_fields() {
  python3 -c 'import json,sys
data = json.load(sys.stdin).get("data", {})
print("|".join([
    str(data.get("status", "unknown")),
    str(data.get("agent", 0)),
]))'
}

detect_vm() {
  local vm_info

  if ! vm_info="$(pve_find_vm "$VMID")"; then
    echo -e "${RED}[✗]${NC} No se encuentra la VM $VMID en el cluster."
    return 1
  fi

  NODE="$(echo "$vm_info" | cut -d'|' -f1)"
  VM_NAME="$(echo "$vm_info" | cut -d'|' -f2)"
  VM_TYPE="$(echo "$vm_info" | cut -d'|' -f3)"

  if [ "$VM_TYPE" != "qemu" ]; then
    echo -e "${RED}[✗]${NC} VMID $VMID no es QEMU (type: $VM_TYPE)."
    return 1
  fi
}

verify_vm_ready() {
  local status_json fields status agent

  status_json="$(pve_vm_status_json "$NODE" "$VMID")"
  fields="$(vm_status_fields <<<"$status_json")"
  status="$(echo "$fields" | cut -d'|' -f1)"
  agent="$(echo "$fields" | cut -d'|' -f2)"

  if [ "$status" != "running" ]; then
    echo -e "${RED}[✗]${NC} VM $VMID no está corriendo (status: $status)"
    return 1
  fi

  echo -e "${GREEN}[✓]${NC} VM corriendo"

  if [ "$agent" = "0" ] || [ "$agent" = "False" ] || [ "$agent" = "None" ]; then
    echo -e "${RED}[✗]${NC} qemu-guest-agent no está habilitado en Proxmox"
    return 1
  fi

  echo -e "${GREEN}[✓]${NC} qemu-guest-agent habilitado"

  if ! guest_run_quiet 30 "true"; then
    echo -e "${RED}[✗]${NC} qemu-guest-agent no responde dentro de la VM"
    return 1
  fi

  echo -e "${GREEN}[✓]${NC} qemu-guest-agent responde"
}

install_docker() {
  echo -e "\n${YELLOW}[*]${NC} Instalando Docker (método oficial)..."

  echo -e "${YELLOW}[*]${NC} Instalando prerequisitos..."
  if ! guest_run_quiet 300 "sh" "-c" "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl"; then
    echo -e "${RED}[✗]${NC} Error instalando prerequisitos"
    return 1
  fi
  echo -e "${GREEN}[✓]${NC} Prerequisitos instalados"

  echo -e "${YELLOW}[*]${NC} Configurando repositorio de Docker..."
  if ! guest_run_quiet 60 "install" "-m" "0755" "-d" "/etc/apt/keyrings"; then
    echo -e "${RED}[✗]${NC} Error creando /etc/apt/keyrings"
    return 1
  fi

  if ! guest_run_quiet 120 "sh" "-c" "curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc"; then
    echo -e "${RED}[✗]${NC} Error descargando GPG key de Docker"
    return 1
  fi

  if ! guest_run_quiet 30 "chmod" "a+r" "/etc/apt/keyrings/docker.asc"; then
    echo -e "${RED}[✗]${NC} Error configurando permisos de GPG key"
    return 1
  fi

  local repo_cmd
  repo_cmd='echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list'
  if ! guest_run_quiet 60 "sh" "-c" "$repo_cmd"; then
    echo -e "${RED}[✗]${NC} Error añadiendo repositorio de Docker"
    return 1
  fi
  echo -e "${GREEN}[✓]${NC} Repositorio configurado"

  echo -e "${YELLOW}[*]${NC} Actualizando cache de apt..."
  if ! guest_run_quiet 600 "apt-get" "update"; then
    echo -e "${RED}[✗]${NC} Error actualizando apt"
    return 1
  fi
  echo -e "${GREEN}[✓]${NC} Cache actualizado"

  echo -e "${YELLOW}[*]${NC} Instalando paquetes de Docker..."
  if ! guest_run_quiet 900 "sh" "-c" "DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"; then
    echo -e "${RED}[✗]${NC} Error instalando Docker"
    return 1
  fi
  echo -e "${GREEN}[✓]${NC} Docker instalado"

  echo -e "${YELLOW}[*]${NC} Verificando instalación de Docker..."
  if guest_run 30 "docker" "--version"; then
    echo -e "${GREEN}[✓]${NC} Docker instalado correctamente"
    return 0
  fi

  echo -e "${RED}[✗]${NC} Docker no responde correctamente"
  return 1
}

process_vm() {
  echo -e "\n${YELLOW}==========================================${NC}"
  echo "Detectando ubicación de la VM $VMID..."

  if ! detect_vm; then
    return 0
  fi

  echo "Nodo: $NODE | Nombre: $VM_NAME"
  echo "VMID: $VMID"
  echo "Paquetes: ${PACKAGES[*]}"
  echo -e "${YELLOW}==========================================${NC}"

  echo -e "\n${YELLOW}[*]${NC} Verificando VM..."
  if ! verify_vm_ready; then
    return 0
  fi

  echo -e "\n${YELLOW}[*]${NC} Aplicando correcciones preventivas (sources.list)..."
  if guest_run_quiet 30 "sh" "-c" "sed -i '/^deb cdrom/s/^/#/' /etc/apt/sources.list 2>/dev/null || true"; then
    echo -e "${GREEN}[✓]${NC} Sources.list corregido (CDROM desactivado si existía)"
  else
    echo -e "${YELLOW}[!]${NC} No se pudo modificar sources.list (no crítico)"
  fi

  echo -e "${YELLOW}[*]${NC} Verificando conectividad a internet..."
  if guest_run_quiet 30 "ping" "-c" "1" "8.8.8.8"; then
    echo -e "${GREEN}[✓]${NC} Internet OK"
  else
    echo -e "${YELLOW}[!]${NC} Ping falló; continúo por si apt sale por proxy o ICMP está bloqueado"
  fi

  echo -e "${YELLOW}[*]${NC} Limpiando locks anteriores..."
  guest_run_quiet 60 "sh" "-c" "rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* /var/lib/dpkg/lock-frontend" || true
  guest_run_quiet 180 "dpkg" "--configure" "-a" || true

  echo -e "\n${YELLOW}[*]${NC} Actualizando cache de apt..."
  if ! guest_run 900 "apt-get" "update"; then
    echo -e "${RED}[✗]${NC} Error en apt update"
    return 0
  fi
  echo -e "${GREEN}[✓]${NC} Cache actualizado"

  echo -e "\n${YELLOW}[*]${NC} Instalando paquetes..."
  local install_cmd
  install_cmd="DEBIAN_FRONTEND=noninteractive apt-get install -y $(shell_join "${PACKAGES[@]}")"
  if ! guest_run 1200 "sh" "-c" "$install_cmd"; then
    echo -e "${RED}[✗]${NC} Error en apt install"
    return 0
  fi
  echo -e "${GREEN}[✓]${NC} Instalación completada"

  echo -e "\n${YELLOW}[*]${NC} Verificando instalación..."
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    if guest_run_quiet 30 "dpkg-query" "-W" "-f=\${Status}" "$pkg"; then
      echo -e "${GREEN}[✓]${NC} $pkg instalado"
    else
      echo -e "${RED}[✗]${NC} $pkg no parece instalado"
    fi
  done

  if [ "$INSTALL_DOCKER" -eq 1 ]; then
    install_docker || true
  fi

  echo -e "\n${YELLOW}[*]${NC} VM $VMID procesada"
}

parse_args "$@"
source "${SCRIPT_DIR}/../lib/proxmox-api.sh"

for VMID in "${VMIDS[@]}"; do
  if [[ ! "$VMID" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}[✗]${NC} VMID inválido: $VMID"
    continue
  fi

  NODE=""
  VM_NAME=""
  VM_TYPE=""
  process_vm
done

echo -e "\n${GREEN}==========================================${NC}"
echo "Proceso completado"
echo -e "==========================================${NC}"
