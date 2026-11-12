#!/usr/bin/env bash
# vm_inventory.sh — Writes a Markdown inventory of the cluster: nodes, VMs, containers and what runs inside
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [--out FILE]

Read-only. Collects from the Proxmox API every node, VM and LXC (resources, disks,
GPUs, IPs, tags and the Notes field) and, through the qemu-guest-agent of running
VMs, the LXD containers and Docker containers inside them. Renders it as Markdown.

With --out the file is updated in place: only the part between
'<!-- inventory:start -->' and '<!-- inventory:end -->' is rewritten, so text
written by hand outside the markers is kept. A new file gets a skeleton.

The Notes field of each VM/LXC (Proxmox UI > Summary > Notes) is the place to
say what runs there; it is copied as is, except lines that look like credentials
(pass, password, token, secret...), which are left out.

Script options:
  --out FILE        Markdown file to update (default: \$INVENTORY_OUT, else stdout)
  --no-guest        Do not query inside the VMs (no LXD / Docker lists)

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -h, --help        This help

Examples:
  $(basename "$0") --out "/mnt/c/Users/me/Vault/clusteria/Inventario.md"
  $(basename "$0") --no-guest | less
EOF
}

OUT="${INVENTORY_OUT:-}"
GUEST=1

while (($# > 0)); do
  case "$1" in
    --out) need_value "$1" "${2:-}"; OUT="$2"; shift 2 ;;
    --no-guest) GUEST=0; shift ;;
    *) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
  esac
done
((${#VMIDS[@]} == 0)) || die_usage "This script takes no VMIDs: it always covers the whole cluster"

load_cluster
print_target >&2

WORK="$(mktemp -d)"
if [[ -n "${INVENTORY_KEEP:-}" ]]; then log_info "Raw data kept in $WORK" >&2; else trap 'rm -rf "$WORK"' EXIT; fi
mkdir -p "$WORK"/{node,pci,storage,cfg,ip,guest}

# Inside a running VM: LXD instances (only if the LXD snap is there: /usr/sbin/lxc on Ubuntu
# 24.04 is lxd-installer and would install LXD) and Docker containers, as compact JSON lines.
# shellcheck disable=SC2016  # expanded inside the VM
GUEST_SCRIPT='if [ -x /snap/bin/lxc ]; then
/snap/bin/lxc list --format json 2>/dev/null | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    cfg, dev = c.get(\"expanded_config\", {}), c.get(\"expanded_devices\", {})
    eth0 = ((c.get(\"state\") or {}).get(\"network\") or {}).get(\"eth0\") or {}
    ips = [a[\"address\"] for a in eth0.get(\"addresses\", []) if a.get(\"family\") == \"inet\"]
    print(\"LXD \" + json.dumps({
        \"name\": c[\"name\"], \"status\": c[\"status\"], \"description\": c.get(\"description\", \"\"),
        \"ip\": ips, \"cpu\": cfg.get(\"limits.cpu\", \"\"), \"memory\": cfg.get(\"limits.memory\", \"\"),
        \"disk\": (dev.get(\"root\") or {}).get(\"size\", \"\"),
        \"gpu\": [d.get(\"gputype\", \"physical\") + (\":\" + cfg.get(\"user.miglxd.profile\", \"\") if d.get(\"gputype\") == \"mig\" else \"\")
                for d in dev.values() if d.get(\"type\") == \"gpu\"],
        \"ports\": [d[\"listen\"].rsplit(\":\", 1)[-1] + \"->\" + d.get(\"connect\", \"\").rsplit(\":\", 1)[-1]
                  for d in dev.values() if d.get(\"type\") == \"proxy\" and \"listen\" in d],
        \"users\": [u for u in cfg.get(\"user.miglxd.users\", \"\").split(\",\") if u]}))
"
fi
if command -v docker >/dev/null 2>&1; then docker ps -a --format "DOCKER {{json .}}" 2>/dev/null; fi
true'

# get PATH FILE [args] — one API read into a file; errors are tolerated (missing data is shown as such)
get() {
  local path="$1" file="$2"
  shift 2
  if ! pve get "$path" "$@" >"$file" 2>>"$WORK/errors.log"; then
    echo null >"$file"
    FAILED_READS=$((FAILED_READS + 1))
  fi
}
FAILED_READS=0

log_info "Reading nodes and guests..." >&2
get /cluster/resources "$WORK/resources.json"
get /nodes "$WORK/nodes.json"
mapfile -t NODES < <(json_get '"\n".join(n["node"] for n in (d or []) if n.get("status") == "online")' <"$WORK/nodes.json")
for n in "${NODES[@]}"; do
  [[ -n "$n" ]] || continue
  get "/nodes/$n/status" "$WORK/node/$n.json"
  get "/nodes/$n/hardware/pci" "$WORK/pci/$n.json"
  get "/nodes/$n/storage" "$WORK/storage/$n.json"
done

mapfile -t GUESTS < <(json_get '"\n".join(" ".join(str(v.get(k) or 0) for k in ("vmid", "node", "type", "status", "template"))
  for v in (d or []) if v.get("type") in ("qemu", "lxc"))' <"$WORK/resources.json")
for line in "${GUESTS[@]}"; do
  [[ -n "$line" ]] || continue
  read -r id node type status template <<<"$line"
  get "/nodes/$node/$type/$id/config" "$WORK/cfg/$id.json"
  [[ "$status" == running && "$template" != 1 ]] || continue
  if [[ "$type" == lxc ]]; then
    get "/nodes/$node/lxc/$id/interfaces" "$WORK/ip/$id.json"
  elif [[ "$(json_get 'str(d.get("agent", "0")).split(",")[0] in ("1", "enabled=1")' <"$WORK/cfg/$id.json")" == 1 ]]; then
    get "/nodes/$node/qemu/$id/agent/network-get-interfaces" "$WORK/ip/$id.json"
    ostype="$(json_get 'd.get("ostype", "")' <"$WORK/cfg/$id.json")"
    if ((GUEST)) && [[ ! "$ostype" =~ ^(win|wxp|w2k) ]]; then
      NODE="$node" GUEST_TIMEOUT=60 guest_sh_query "$id" "$GUEST_SCRIPT" >/dev/null 2>&1 || true
      printf '%s\n' "$GUEST_OUT" >"$WORK/guest/$id.txt"
    fi
  fi
done

((FAILED_READS == 0)) || { log_warn "$FAILED_READS API reads failed (shown as '-'):" >&2; sort -u "$WORK/errors.log" | head -5 >&2; }
log_info "Rendering..." >&2
python3 "$INFRA_ROOT/vm/vm_inventory.py" "$WORK" "$CLUSTER_NAME" "$OUT"
[[ -z "$OUT" ]] || log_ok "Inventory written to $OUT" >&2
