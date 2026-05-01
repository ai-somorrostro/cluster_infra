#!/usr/bin/env bash
set -euo pipefail

vars_file="${VARS_FILE:-variables.pkrvars.hcl}"
build_id="${BUILD_ID:-9000}"
template_id="${TEMPLATE_ID:-9001}"
final_storage="${FINAL_STORAGE:-ssd-data}"
final_name="${FINAL_NAME:-ubuntu-server-24}"

read_var() {
  local key="$1"
  python3 - "$key" "$vars_file" <<'PY'
import re
import sys

key, path = sys.argv[1:3]
pattern = re.compile(r'^\s*' + re.escape(key) + r'\s*=\s*(?:"([^"]*)"|(\d+))')
for line in open(path, encoding="utf-8"):
    match = pattern.match(line)
    if match:
        print(match.group(1) or match.group(2))
        break
PY
}

api_url="$(read_var proxmox_api_url)"
node="$(read_var proxmox_node)"
token_id="$(read_var proxmox_api_token_id)"
token_secret="$(read_var proxmox_api_token_secret)"
base_url="${api_url%/api2/json}/api2/json"
auth_header="Authorization: PVEAPIToken=${token_id}=${token_secret}"

api() {
  local method="$1"
  local path="$2"
  shift 2

  curl -sk -X "$method" -H "$auth_header" "$@" "${base_url}${path}"
}

json_data() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("data") or "")'
}

urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

wait_task() {
  local task="$1"
  local encoded
  encoded="$(urlencode "$task")"

  while true; do
    local status
    status="$(
      api GET "/nodes/${node}/tasks/${encoded}/status" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d.get("status","") + " " + str(d.get("exitstatus","")))'
    )"
    case "$status" in
      "stopped OK"|"stopped None")
        return 0
        ;;
      stopped*)
        echo "Proxmox task failed: $status" >&2
        return 1
        ;;
    esac
    sleep 2
  done
}

vm_exists() {
  local vmid="$1"
  local status_code
  status_code="$(
    curl -sk -o /dev/null -w "%{http_code}" -H "$auth_header" \
      "${base_url}/nodes/${node}/qemu/${vmid}/status/current"
  )"
  [ "$status_code" = "200" ]
}

destroy_vm() {
  local vmid="$1"
  if ! vm_exists "$vmid"; then
    echo "VM ${vmid} does not exist."
    return 0
  fi

  echo "Destroying VM ${vmid}..."
  local task
  task="$(api DELETE "/nodes/${node}/qemu/${vmid}" | json_data)"
  [ -z "$task" ] || wait_task "$task"
}

set_dhcp() {
  local vmid="$1"
  echo "Setting DHCP cloud-init config on ${vmid}..."
  api PUT "/nodes/${node}/qemu/${vmid}/config" \
    --data-urlencode "ipconfig0=ip=dhcp" \
    --data-urlencode "delete=nameserver,searchdomain" \
    >/dev/null
}

distribute() {
  destroy_vm "$template_id"

  echo "Cloning ${build_id} -> ${template_id} on ${final_storage}..."
  local task
  task="$(
    api POST "/nodes/${node}/qemu/${build_id}/clone" \
      --data-urlencode "newid=${template_id}" \
      --data-urlencode "full=1" \
      --data-urlencode "storage=${final_storage}" \
      --data-urlencode "name=${final_name}" \
      | json_data
  )"
  if [ -z "$task" ]; then
    echo "Clone API did not return a task id." >&2
    return 1
  fi
  wait_task "$task"

  set_dhcp "$template_id"
  echo "Converting ${template_id} to template..."
  task="$(api POST "/nodes/${node}/qemu/${template_id}/template" | json_data)"
  [ -z "$task" ] || wait_task "$task"
}

case "${1:-}" in
  dhcp)
    set_dhcp "$build_id"
    ;;
  distribute)
    distribute
    ;;
  clean-build)
    destroy_vm "$build_id"
    ;;
  clean-final)
    destroy_vm "$template_id"
    ;;
  *)
    echo "Usage: $0 {dhcp|distribute|clean-build|clean-final}" >&2
    exit 2
    ;;
esac
