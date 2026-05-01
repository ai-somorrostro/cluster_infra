#!/usr/bin/env bash

# Shared Proxmox API helpers for running cluster automation outside PVE nodes.
# Required env vars:
#   PROXMOX_API_URL, PROXMOX_API_TOKEN_ID, PROXMOX_API_TOKEN_SECRET
# Optional:
#   VARS_FILE - Packer-style pkrvars file used as fallback for the same keys.

set -euo pipefail

PVE_API_URL="${PROXMOX_API_URL:-}"
PVE_TOKEN_ID="${PROXMOX_API_TOKEN_ID:-}"
PVE_TOKEN_SECRET="${PROXMOX_API_TOKEN_SECRET:-}"
PVE_VARS_FILE="${VARS_FILE:-}"

pve_read_var() {
  local key="$1"
  local path="$2"

  [ -f "$path" ] || return 0

  python3 - "$key" "$path" <<'PY'
import re
import sys

key, path = sys.argv[1:3]
pattern = re.compile(r'^\s*' + re.escape(key) + r'\s*=\s*(?:"([^"]*)"|(\d+))')

with open(path, encoding="utf-8") as handle:
    for line in handle:
        match = pattern.match(line)
        if match:
            print(match.group(1) or match.group(2))
            break
PY
}

pve_init() {
  if [ -n "$PVE_VARS_FILE" ]; then
    PVE_API_URL="${PVE_API_URL:-$(pve_read_var proxmox_api_url "$PVE_VARS_FILE")}"
    PVE_TOKEN_ID="${PVE_TOKEN_ID:-$(pve_read_var proxmox_api_token_id "$PVE_VARS_FILE")}"
    PVE_TOKEN_SECRET="${PVE_TOKEN_SECRET:-$(pve_read_var proxmox_api_token_secret "$PVE_VARS_FILE")}"
  fi

  if [ -z "$PVE_API_URL" ] || [ -z "$PVE_TOKEN_ID" ] || [ -z "$PVE_TOKEN_SECRET" ]; then
    cat >&2 <<'EOF'
Missing Proxmox API credentials.

Set:
  PROXMOX_API_URL
  PROXMOX_API_TOKEN_ID
  PROXMOX_API_TOKEN_SECRET

Or pass VARS_FILE pointing to a variables.pkrvars.hcl with:
  proxmox_api_url
  proxmox_api_token_id
  proxmox_api_token_secret
EOF
    return 1
  fi

  PVE_API_URL="${PVE_API_URL%/}"
  PVE_API_URL="${PVE_API_URL%/api2/json}/api2/json"
  PVE_AUTH_HEADER="Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}"
}

pve_api() {
  local method="$1"
  local path="$2"
  shift 2

  curl -skS --fail-with-body -X "$method" -H "$PVE_AUTH_HEADER" "$@" "${PVE_API_URL}${path}"
}

pve_json_data() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("data") or "")'
}

pve_urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

pve_find_vm() {
  local vmid="$1"

  pve_api GET "/cluster/resources?type=vm" \
    | python3 -c 'import json,sys
vmid = int(sys.argv[1])
items = json.load(sys.stdin).get("data", [])
vm = next((item for item in items if item.get("vmid") == vmid), None)
if not vm:
    sys.exit(1)
print("|".join([
    str(vm.get("node", "")),
    str(vm.get("name", "")),
    str(vm.get("type", "")),
    str(vm.get("status", "")),
]))' "$vmid"
}

pve_vm_node() {
  pve_find_vm "$1" | cut -d'|' -f1
}

pve_vm_status_json() {
  local node="$1"
  local vmid="$2"

  pve_api GET "/nodes/${node}/qemu/${vmid}/status/current"
}

pve_wait_task() {
  local node="$1"
  local task="$2"
  local timeout="${3:-600}"
  local encoded
  local waited=0

  encoded="$(pve_urlencode "$task")"

  while [ "$waited" -lt "$timeout" ]; do
    local status
    status="$(
      pve_api GET "/nodes/${node}/tasks/${encoded}/status" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d.get("status","") + "|" + str(d.get("exitstatus","")))'
    )"

    case "$status" in
      "stopped|OK"|"stopped|None")
        return 0
        ;;
      stopped*)
        echo "Proxmox task failed: $status" >&2
        return 1
        ;;
    esac

    sleep 2
    waited=$((waited + 2))
  done

  echo "Timed out waiting for Proxmox task: $task" >&2
  return 1
}

pve_guest_exec() {
  local node="$1"
  local vmid="$2"
  shift 2

  local args=()
  for arg in "$@"; do
    args+=(--data-urlencode "command=${arg}")
  done

  pve_api POST "/nodes/${node}/qemu/${vmid}/agent/exec" "${args[@]}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data", {}).get("pid", ""))'
}

pve_guest_exec_status() {
  local node="$1"
  local vmid="$2"
  local pid="$3"

  pve_api GET "/nodes/${node}/qemu/${vmid}/agent/exec-status?pid=${pid}"
}

pve_guest_exec_wait() {
  local node="$1"
  local vmid="$2"
  local timeout="$3"
  shift 3

  local pid
  if ! pid="$(pve_guest_exec "$node" "$vmid" "$@")" || [ -z "$pid" ]; then
    echo "Could not start guest-agent command on VM ${vmid}" >&2
    return 1
  fi

  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local status
    if ! status="$(pve_guest_exec_status "$node" "$vmid" "$pid")"; then
      echo "Could not read guest-agent command status pid ${pid} on VM ${vmid}" >&2
      return 1
    fi

    if echo "$status" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("data", {}).get("exited") else 1)' 2>/dev/null; then
      echo "$status"
      return "$(echo "$status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data", {}).get("exitcode", 1))')"
    fi

    sleep 1
    waited=$((waited + 1))
  done

  echo "Timed out waiting for guest-agent command pid ${pid} on VM ${vmid}" >&2
  return 1
}

pve_guest_exec_output() {
  python3 -c 'import base64,json,sys
data = json.load(sys.stdin).get("data", {})
for key in ("out-data", "err-data"):
    value = data.get(key)
    if not value:
        continue
    try:
        decoded = base64.b64decode(value).decode("utf-8", "replace")
    except Exception:
        decoded = value
    stream = sys.stdout if key == "out-data" else sys.stderr
    print(decoded, end="" if decoded.endswith("\n") else "\n", file=stream)'
}

pve_init
