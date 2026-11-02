#!/usr/bin/env bash
# Load repo-root .env and optional Packer variables into PROXMOX_* / VARS_FILE.
# Safe to source from any script; does not change set -e / -u / pipefail.
# Idempotent: safe to source multiple times (e.g. before and with proxmox-api.sh).

if [ -n "${_PVE_LOAD_ENV_DONE:-}" ]; then
  [[ "${BASH_SOURCE[0]}" == "${0}" ]] && exit 0 || return 0
fi

_pve_lib_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PVE_REPO_ROOT="$(cd -- "${_pve_lib_dir}/.." && pwd)"

: "${PROXMOX_ENV_FILE:=${PVE_REPO_ROOT}/.env}"
if [ -f "${PROXMOX_ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${PROXMOX_ENV_FILE}"
  set +a
fi

_default_pkrvars="${PVE_REPO_ROOT}/templates/VMs/ubuntu-server-24-http/variables.pkrvars.hcl"
if [ -z "${VARS_FILE:-}" ] && [ -f "${_default_pkrvars}" ]; then
  VARS_FILE="${_default_pkrvars}"
fi

pve_read_pkrvar() {
  local key="$1"
  local path="$2"

  [ -f "$path" ] || return 0

  python3 - "$key" "$path" <<'PY'
import re
import sys

key, path = sys.argv[1:3]
pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=\s*(?:\"([^\"]*)\"|(\d+))")
with open(path, encoding="utf-8") as handle:
    for line in handle:
        match = pattern.match(line)
        if match:
            print(match.group(1) or match.group(2))
            break
PY
}

pve_merge_pkrvars_into_env() {
  [ -n "${VARS_FILE:-}" ] && [ -f "${VARS_FILE}" ] || return 0
  PROXMOX_API_URL="${PROXMOX_API_URL:-$(pve_read_pkrvar proxmox_api_url "$VARS_FILE")}"
  PROXMOX_API_TOKEN_ID="${PROXMOX_API_TOKEN_ID:-$(pve_read_pkrvar proxmox_api_token_id "$VARS_FILE")}"
  PROXMOX_API_TOKEN_SECRET="${PROXMOX_API_TOKEN_SECRET:-$(pve_read_pkrvar proxmox_api_token_secret "$VARS_FILE")}"
  export PROXMOX_API_URL PROXMOX_API_TOKEN_ID PROXMOX_API_TOKEN_SECRET VARS_FILE
}

pve_merge_pkrvars_into_env

export PVE_REPO_ROOT
_PVE_LOAD_ENV_DONE=1
