#!/usr/bin/env bash
# lib/pve_common.sh — Shared library for the infra scripts (Proxmox cluster).
#
# Usage from a script:
#   source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"
#
# Provides:
#   - log_*/die/confirm ............ consistent output
#   - parse_common_opt/prepare_run . common CLI contract (-h -n -y -c -f --, vmid, range, vmid:value)
#   - load_cluster/pve/pve_task .... Proxmox API access (local | api | ssh)
#   - vm_locate/vm_begin/... ....... VM lookup and final summary
#   - guest_exec/guest_sh/... ...... running commands inside VMs via qemu-guest-agent
#
# Credentials come from the repo .env (lib/pve-load-env.sh: PROXMOX_API_URL,
# PROXMOX_API_TOKEN_ID, PROXMOX_API_TOKEN_SECRET). config/clusters.conf is optional
# and adds several clusters and fallback nodes.
#
# Docs: docs/script-standard.md
# shellcheck disable=SC2034  # many variables are used by the scripts sourcing this library

[[ -n "${_PVE_COMMON_LOADED:-}" ]] && return 0
_PVE_COMMON_LOADED=1

INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/pve-load-env.sh
source "$INFRA_ROOT/lib/pve-load-env.sh"

# ─── Colors and logging ──────────────────────────────────────────────────────

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[0;31m' C_GREEN=$'\033[0;32m' C_YELLOW=$'\033[1;33m'
  C_CYAN=$'\033[0;36m' C_BOLD=$'\033[1m' C_NC=$'\033[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_NC=""
fi

log_info() { printf '%s[*]%s %s\n' "$C_CYAN" "$C_NC" "$*"; }
log_ok()   { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_NC" "$*"; }
log_warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_NC" "$*"; }
log_err()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_NC" "$*" >&2; }
die()      { log_err "$*"; exit 1; }
die_usage() {
  log_err "$*"
  echo "Run with --help for usage." >&2
  exit 1
}

# confirm "Question" — returns 0 if the user answers y/Y. Always 0 with -y or --dry-run.
confirm() {
  [[ "${ASSUME_YES:-0}" == 1 || "${DRY_RUN:-0}" == 1 ]] && return 0
  [[ -t 0 ]] || die "Confirmation required but there is no interactive terminal (use -y)"
  local r
  read -r -p "$1 [y/N] " r
  [[ "$r" =~ ^[yY]$ ]]
}

# ─── JSON ────────────────────────────────────────────────────────────────────

# json_get 'EXPR' < json — evaluates a Python expression over 'd' (the JSON read from stdin).
#   None → nothing · bool → 1/0 · dict/list → JSON · anything else → str
json_get() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    def u8(x):
        # Proxmox returns the agent out-data/err-data as latin-1: convert back to UTF-8
        try:
            return x.encode("latin-1").decode("utf-8")
        except Exception:
            return x
    v = eval(sys.argv[1], {"d": d, "json": json, "u8": u8})
except Exception:
    sys.exit(1)
if v is None:
    sys.exit(0)
if isinstance(v, bool):
    print(1 if v else 0)
elif isinstance(v, (dict, list)):
    print(json.dumps(v))
else:
    print(v)
' "$1"
}

# ─── Common arguments ────────────────────────────────────────────────────────

DRY_RUN=0
ASSUME_YES=0
VMIDS=()
declare -A VM_VALUES=()
EXTRA_ARGS=()
COMMON_SHIFT=0
_OPT_CLUSTER=""
declare -A _VM_SEEN=()

_add_vm() {
  local vmid="$1" value="${2:-}"
  vmid=$((10#$vmid))
  if [[ -z "${_VM_SEEN[$vmid]:-}" ]]; then
    _VM_SEEN[$vmid]=1
    VMIDS+=("$vmid")
  fi
  [[ -n "$value" ]] && VM_VALUES[$vmid]="$value"
  return 0
}

# _add_vm_token TOKEN — accepts "100", "100-110" or "100:value"
_add_vm_token() {
  local t="$1"
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    _add_vm "$t"
  elif [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]})) i
    ((a <= b)) || die_usage "Invalid range: $t"
    ((b - a <= 500)) || die_usage "Range too large (max 500 VMs): $t"
    for ((i = a; i <= b; i++)); do _add_vm "$i"; done
  elif [[ "$t" =~ ^([0-9]+)[[:space:]]*:[[:space:]]*(.+)$ ]]; then
    _add_vm "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    die_usage "Invalid argument: '$t' (expected vmid, range 100-110 or vmid:value)"
  fi
}

# _add_vms_from_file FILE — one entry per line; blank lines and lines starting with # are ignored
_add_vms_from_file() {
  local f="$1" line
  [[ -f "$f" ]] || die_usage "File not found: $f"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    _add_vm_token "$line"
  done <"$f"
}

# parse_common_opt "$@" — handles one common option or VMID and stores in COMMON_SHIFT
# how many arguments it consumed. Scripts call it from the '*)' branch of their case.
parse_common_opt() {
  COMMON_SHIFT=1
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -n | --dry-run) DRY_RUN=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    -c | --cluster)
      [[ -n "${2:-}" ]] || die_usage "$1 requires a cluster name"
      _OPT_CLUSTER="$2"
      COMMON_SHIFT=2
      ;;
    -f | --file)
      [[ -n "${2:-}" ]] || die_usage "$1 requires a file"
      _add_vms_from_file "$2"
      COMMON_SHIFT=2
      ;;
    --)
      shift
      EXTRA_ARGS=("$@")
      COMMON_SHIFT=$(($# + 1))
      ;;
    -*) die_usage "Unknown option: $1" ;;
    *) _add_vm_token "$1" ;;
  esac
}

# need_value OPTION VALUE — checks that a script-specific option got a value
need_value() {
  [[ -n "${2:-}" && "${2:0:1}" != "-" ]] || die_usage "$1 requires a value"
}

# prepare_run [none|optional|required] — validates VMIDs/values, loads the cluster,
# prints the target and asks for confirmation if the cluster is not the default one.
prepare_run() {
  local values="${1:-none}" v
  ((${#VMIDS[@]} > 0)) || die_usage "Give at least one VMID (or -f file)"
  for v in "${VMIDS[@]}"; do
    case "$values" in
      none) [[ -z "${VM_VALUES[$v]:-}" ]] || die_usage "This script does not accept 'vmid:value' ($v:${VM_VALUES[$v]})" ;;
      required) [[ -n "${VM_VALUES[$v]:-}" ]] || die_usage "Missing value for VM $v (format vmid:value)" ;;
    esac
  done
  load_cluster
  print_target
  if [[ "$CLUSTER_IS_DEFAULT" != 1 && "$DRY_RUN" != 1 ]]; then
    confirm "Cluster '$CLUSTER_NAME' is NOT the default one. Continue?" || die "Cancelled"
  fi
}

print_target() {
  local extra=""
  [[ "$DRY_RUN" == 1 ]] && extra=" ${C_YELLOW}[DRY-RUN: nothing will be changed]${C_NC}"
  printf '%sCluster:%s %s (via %s, %s)%s\n' "$C_BOLD" "$C_NC" "$CLUSTER_NAME" "$CLUSTER_HOST_NAME" "$CLUSTER_MODE" "$extra"
  ((${#VMIDS[@]} > 0)) && printf '%sVMs:%s %s\n' "$C_BOLD" "$C_NC" "${VMIDS[*]}"
  return 0
}

# ─── Target cluster ──────────────────────────────────────────────────────────

PVE_CLUSTERS_CONF="${PVE_CLUSTERS_CONF:-$INFRA_ROOT/config/clusters.conf}"
CLUSTER_NAME=""
CLUSTER_MODE=""
CLUSTER_HOST=""
CLUSTER_HOST_NAME=""
CLUSTER_HOSTS=""
CLUSTER_USER="root"
CLUSTER_API_TOKEN=""
CLUSTER_API_PORT=8006
CLUSTER_VERIFY_TLS=0
CLUSTER_IS_DEFAULT=1

_cluster_var() {
  local n="CLUSTER_${CLUSTER_NAME}_$1"
  printf '%s' "${!n:-}"
}

_local_cluster_name() {
  [[ -r /etc/pve/corosync.conf ]] || return 0
  awk '/cluster_name:/ {print $2; exit}' /etc/pve/corosync.conf
}

# Token from .env (PROXMOX_API_TOKEN_ID / _SECRET), if any
_env_api_token() {
  [[ -n "${PROXMOX_API_TOKEN_ID:-}" && -n "${PROXMOX_API_TOKEN_SECRET:-}" ]] || return 0
  printf '%s=%s' "$PROXMOX_API_TOKEN_ID" "$PROXMOX_API_TOKEN_SECRET"
}

_probe_host() {
  local addr="$1"
  case "$CLUSTER_MODE" in
    api)
      local -a k=()
      [[ "$CLUSTER_VERIFY_TLS" == 1 ]] || k=(-k)
      [[ "$(curl -s "${k[@]}" -m 4 -o /dev/null -w '%{http_code}' \
        -H "Authorization: PVEAPIToken=${CLUSTER_API_TOKEN}" \
        "https://${addr}:${CLUSTER_API_PORT}/api2/json/version")" == 200 ]]
      ;;
    ssh) ssh -o BatchMode=yes -o ConnectTimeout=4 "${CLUSTER_USER}@${addr}" true >/dev/null 2>&1 ;;
  esac
}

# load_cluster — picks the cluster and the transport.
#   With config/clusters.conf: -c > $PVE_CLUSTER > DEFAULT_CLUSTER, with fallback nodes.
#   Without it: pvesh if this is a Proxmox node, otherwise the API from .env (PROXMOX_API_URL).
load_cluster() {
  [[ -n "$CLUSTER_MODE" ]] && return 0
  local requested="${_OPT_CLUSTER:-${PVE_CLUSTER:-}}"

  if [[ ! -f "$PVE_CLUSTERS_CONF" ]]; then
    [[ -z "$requested" ]] || die "Cluster '$requested' requested but $PVE_CLUSTERS_CONF does not exist (copy config/clusters.conf.example)"
    if [[ -n "$(_local_cluster_name)" ]] && command -v pvesh >/dev/null 2>&1; then
      CLUSTER_NAME="$(_local_cluster_name)"
      CLUSTER_MODE=local
      CLUSTER_HOST_NAME="$(hostname -s)"
      return 0
    fi
    if [[ -n "${PROXMOX_API_URL:-}" ]]; then
      CLUSTER_API_TOKEN="${PVE_API_TOKEN:-$(_env_api_token)}"
      [[ -n "$CLUSTER_API_TOKEN" ]] || die "PROXMOX_API_URL is set but PROXMOX_API_TOKEN_ID / PROXMOX_API_TOKEN_SECRET are missing (.env)"
      local hostport="${PROXMOX_API_URL#*://}"
      hostport="${hostport%%/*}"
      CLUSTER_HOST="${hostport%%:*}"
      [[ "$hostport" == *:* ]] && CLUSTER_API_PORT="${hostport##*:}"
      CLUSTER_MODE=api
      _probe_host "$CLUSTER_HOST" || die "Proxmox API not reachable at $PROXMOX_API_URL (check .env)"
      local status
      status="$(_pve_api get /cluster/status)" || die "Could not read /cluster/status"
      CLUSTER_NAME="$(json_get "next((x.get('name') for x in d if x.get('type') == 'cluster'), 'standalone')" <<<"$status")"
      CLUSTER_HOST_NAME="$(json_get "next((x.get('name') for x in d if x.get('type') == 'node' and x.get('ip') == '$CLUSTER_HOST'), '$CLUSTER_HOST')" <<<"$status")"
      return 0
    fi
    if command -v pvesh >/dev/null 2>&1; then
      CLUSTER_NAME=local
      CLUSTER_MODE=local
      CLUSTER_HOST_NAME="$(hostname -s)"
      return 0
    fi
    die "No Proxmox target: create .env from .env.example (PROXMOX_API_*) or config/clusters.conf, or run on a Proxmox node"
  fi

  # shellcheck source=/dev/null
  source "$PVE_CLUSTERS_CONF"
  CLUSTER_NAME="${requested:-${DEFAULT_CLUSTER:-}}"
  [[ -n "$CLUSTER_NAME" ]] || die "No cluster: use -c/--cluster or set DEFAULT_CLUSTER in $PVE_CLUSTERS_CONF"
  [[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "Invalid cluster name: $CLUSTER_NAME"
  CLUSTER_HOSTS="$(_cluster_var HOSTS)"
  [[ -n "$CLUSTER_HOSTS" ]] || die "Cluster '$CLUSTER_NAME' is not defined in $PVE_CLUSTERS_CONF (missing CLUSTER_${CLUSTER_NAME}_HOSTS)"
  [[ "$CLUSTER_NAME" == "${DEFAULT_CLUSTER:-}" ]] && CLUSTER_IS_DEFAULT=1 || CLUSTER_IS_DEFAULT=0

  local v
  v="$(_cluster_var USER)" && CLUSTER_USER="${v:-root}"
  CLUSTER_API_TOKEN="${PVE_API_TOKEN:-$(_cluster_var API_TOKEN)}"
  [[ -n "$CLUSTER_API_TOKEN" || "$CLUSTER_IS_DEFAULT" != 1 ]] || CLUSTER_API_TOKEN="$(_env_api_token)"
  v="$(_cluster_var API_PORT)" && CLUSTER_API_PORT="${v:-8006}"
  v="$(_cluster_var VERIFY_TLS)" && CLUSTER_VERIFY_TLS="${v:-0}"

  local mode
  mode="$(_cluster_var MODE)"
  mode="${mode:-auto}"
  if [[ "$mode" == auto ]]; then
    if [[ "$(_local_cluster_name)" == "$CLUSTER_NAME" ]]; then
      mode=local
    elif [[ -n "$CLUSTER_API_TOKEN" ]]; then
      mode=api
    else
      mode=ssh
    fi
  fi
  CLUSTER_MODE="$mode"

  case "$mode" in
    local)
      [[ "$(_local_cluster_name)" == "$CLUSTER_NAME" ]] ||
        die "MODE=local but this machine is not a node of cluster '$CLUSTER_NAME'"
      CLUSTER_HOST_NAME="$(hostname -s)"
      ;;
    api | ssh)
      [[ "$mode" == api && -z "$CLUSTER_API_TOKEN" ]] &&
        die "MODE=api but there is no token (CLUSTER_${CLUSTER_NAME}_API_TOKEN, \$PVE_API_TOKEN or PROXMOX_API_TOKEN_* in .env)"
      local entry name addr
      for entry in $CLUSTER_HOSTS; do
        name="${entry%%:*}"
        addr="${entry#*:}"
        if _probe_host "$addr"; then
          CLUSTER_HOST="$addr"
          CLUSTER_HOST_NAME="$name"
          break
        fi
        log_warn "Node $name ($addr) does not answer via $mode; trying the next one..." >&2
      done
      [[ -n "$CLUSTER_HOST" ]] || die "No node of cluster '$CLUSTER_NAME' answers via $mode ($CLUSTER_HOSTS)"
      ;;
    *) die "Unknown MODE '$mode' for cluster $CLUSTER_NAME (auto | local | api | ssh)" ;;
  esac
}

# node_address NODE — node IP: from clusters.conf, otherwise from /cluster/status, otherwise the name
node_address() {
  local entry ip
  for entry in $CLUSTER_HOSTS; do
    [[ "${entry%%:*}" == "$1" ]] && {
      printf '%s' "${entry#*:}"
      return 0
    }
  done
  if [[ -n "$CLUSTER_MODE" ]]; then
    ip="$(pve get /cluster/status 2>/dev/null | json_get "next((x.get('ip') for x in d if x.get('type') == 'node' and x.get('name') == '$1'), '')")" || ip=""
    [[ -n "$ip" ]] && {
      printf '%s' "$ip"
      return 0
    }
  fi
  printf '%s' "$1"
}

# ─── Proxmox API ─────────────────────────────────────────────────────────────

# pve <get|create|set|delete> <path> [--key value]...
# Prints the 'data' field of the response as JSON. In --dry-run, modifying methods are
# only shown (except with _PVE_FORCE=1, used for reads that go through POST).
pve() {
  local method="$1" path="$2"
  shift 2
  if [[ "$method" != get && "$DRY_RUN" == 1 && "${_PVE_FORCE:-0}" != 1 ]]; then
    printf '    %s[dry-run]%s pve %s %s %s\n' "$C_YELLOW" "$C_NC" "$method" "$path" "$(_fmt_args "$@")" >&2
    return 0
  fi
  load_cluster
  case "$CLUSTER_MODE" in
    local) pvesh "$method" "$path" "$@" --output-format json ;;
    ssh) _pve_ssh "$method" "$path" "$@" ;;
    api) _pve_api "$method" "$path" "$@" ;;
  esac
}

# pve_root <method> <path> [args] — for what Proxmox only allows to root@pam with a real
# session (config 'args', monitor, ...). API tokens are rejected: in api mode this goes via ssh.
pve_root() {
  if [[ "$CLUSTER_MODE" == api && "$DRY_RUN" != 1 ]]; then
    local errf rc=0
    errf="$(mktemp)"
    _pve_ssh "$@" 2>"$errf" || rc=$?
    if ((rc != 0)); then
      cat "$errf" >&2
      grep -qiE "permission denied|connection|resolve|timed out" "$errf" &&
        log_err "'$2' is only allowed to root@pam (not an API token): run the script on a node or enable ssh (ssh-copy-id ${CLUSTER_USER}@${CLUSTER_HOST})"
    fi
    rm -f "$errf"
    return "$rc"
  fi
  pve "$@"
}

_fmt_args() {
  local out="" a
  for a in "$@"; do
    ((${#a} > 80)) && a="${a:0:77}..."
    a="${a//$'\n'/⏎}"
    [[ "$a" =~ [[:space:]] ]] && a="'$a'"
    out+="$a "
  done
  printf '%s' "${out% }"
}

_pve_ssh() {
  local q
  q="$(printf '%q ' pvesh "$@" --output-format json)"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${CLUSTER_USER}@${CLUSTER_HOST}" "$q"
}

_pve_api() {
  local method="$1" path="$2" http
  shift 2
  case "$method" in
    get) http=GET ;;
    create) http=POST ;;
    set) http=PUT ;;
    delete) http=DELETE ;;
    *) die "pve: unknown method '$method'" ;;
  esac
  local -a data=()
  while (($# > 0)); do
    [[ "$1" == --* && $# -ge 2 ]] || die "pve: expected '--key value', got '$1'"
    data+=(--data-urlencode "${1#--}=$2")
    shift 2
  done
  local -a opts=(-s -m "${PVE_API_TIMEOUT:-120}" -X "$http"
    -H "Authorization: PVEAPIToken=${CLUSTER_API_TOKEN}")
  [[ "$CLUSTER_VERIFY_TLS" == 1 ]] || opts+=(-k)
  [[ "$http" == GET || "$http" == DELETE ]] && opts+=(-G)

  local body hdr status rc=0
  body="$(mktemp)"
  hdr="$(mktemp)"
  status="$(curl "${opts[@]}" "${data[@]}" -D "$hdr" -o "$body" -w '%{http_code}' \
    "https://${CLUSTER_HOST}:${CLUSTER_API_PORT}/api2/json${path}")" || status=000
  if [[ "$status" != 2* ]]; then
    local reason
    reason="$(head -1 "$hdr" | cut -d' ' -f3- | tr -d '\r')"
    log_err "API $http $path → HTTP $status ${reason}"
    rc=1
  else
    python3 -c 'import sys, json; print(json.dumps(json.load(sys.stdin).get("data")))' <"$body" || rc=1
  fi
  rm -f "$body" "$hdr"
  return "$rc"
}

# pve_wait_task NODE UPID [timeout_s] — waits for a task to finish and checks it ended OK
pve_wait_task() {
  local node="$1" upid="$2" timeout="${3:-900}" waited=0 st
  [[ "$upid" == UPID:* ]] || return 0
  while ((waited < timeout)); do
    st="$(pve get "/nodes/$node/tasks/$upid/status" 2>/dev/null)" || st=""
    if [[ -n "$st" && "$(json_get 'd.get("status")' <<<"$st")" == stopped ]]; then
      local es
      es="$(json_get 'd.get("exitstatus","")' <<<"$st")"
      [[ "$es" == OK || "$es" == WARNINGS* ]] && return 0
      log_err "Task failed: $es"
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  log_err "Timeout (${timeout}s) waiting for task $upid"
  return 1
}

# pve_task <method> <path> [args] — like pve, but if it returns a UPID waits for the task to finish
pve_task() {
  local out upid
  out="$(pve "$@")" || return 1
  [[ -n "$out" ]] || return 0
  upid="$(json_get 'd if isinstance(d, str) else None' <<<"$out")" || return 0
  [[ "$upid" == UPID:* ]] || return 0
  pve_wait_task "$(cut -d: -f2 <<<"$upid")" "$upid" "${PVE_TASK_TIMEOUT:-900}"
}

# ─── VM lookup ───────────────────────────────────────────────────────────────

NODE=""
VM_NAME=""
VM_STATUS=""
VM_TYPE=""
VM_TEMPLATE=0
_RESOURCES_JSON=""

# cluster_resources_refresh — re-reads /cluster/resources (cached per run)
cluster_resources_refresh() {
  _RESOURCES_JSON="$(pve get /cluster/resources --type vm)" || die "Could not read /cluster/resources from cluster $CLUSTER_NAME"
}

# vm_locate VMID — sets NODE, VM_NAME, VM_STATUS, VM_TYPE, VM_TEMPLATE. Fails if the VM does not exist.
vm_locate() {
  local vmid="$1" info
  [[ -n "$_RESOURCES_JSON" ]] || cluster_resources_refresh
  info="$(json_get "next(('%s|%s|%s|%s|%s' % (v.get('node',''), v.get('name',''), v.get('status',''), v.get('type',''), v.get('template',0))
                     for v in d if v.get('vmid') == $vmid), '')" <<<"$_RESOURCES_JSON")"
  [[ -n "$info" ]] || return 1
  IFS='|' read -r NODE VM_NAME VM_STATUS VM_TYPE VM_TEMPLATE <<<"$info"
}

# vm_current_status VMID — live status (running, stopped...)
vm_current_status() {
  pve get "/nodes/$NODE/qemu/$1/status/current" | json_get 'd.get("status","unknown")'
}

# vm_config VMID — VM config as JSON
vm_config() {
  pve get "/nodes/$NODE/qemu/$1/config"
}

# vm_require_agent VMID — the VM must be running with the qemu-guest-agent answering
vm_require_agent() {
  local vmid="$1" st
  st="$(pve get "/nodes/$NODE/qemu/$vmid/status/current")" || return 1
  if [[ "$(json_get 'd.get("status","")' <<<"$st")" != running ]]; then
    log_err "VM $vmid is not running"
    return 1
  fi
  if [[ "$(json_get 'd.get("agent",0)' <<<"$st")" != 1 ]]; then
    log_err "VM $vmid does not have the qemu-guest-agent enabled in its config"
    return 1
  fi
  if ! _PVE_FORCE=1 pve create "/nodes/$NODE/qemu/$vmid/agent/ping" >/dev/null 2>&1; then
    log_err "The qemu-guest-agent of VM $vmid does not answer"
    return 1
  fi
}

# vm_shutdown VMID [wait_s=180] [force=0] — clean shutdown; with force=1 does a stop if it does not power off
vm_shutdown() {
  local vmid="$1" wait="${2:-180}" force="${3:-0}" waited=0
  if [[ "$DRY_RUN" == 1 ]]; then
    pve create "/nodes/$NODE/qemu/$vmid/status/shutdown"
    return 0
  fi
  pve create "/nodes/$NODE/qemu/$vmid/status/shutdown" --timeout "$wait" >/dev/null || true
  while ((waited < wait)); do
    [[ "$(vm_current_status "$vmid")" == stopped ]] && return 0
    sleep 2
    waited=$((waited + 2))
  done
  if [[ "$force" == 1 ]]; then
    log_warn "Did not power off in ${wait}s; forcing stop"
    pve_task create "/nodes/$NODE/qemu/$vmid/status/stop"
    return
  fi
  log_err "VM $vmid did not power off in ${wait}s"
  return 1
}

vm_start()  { pve_task create "/nodes/$NODE/qemu/$1/status/start"; }
vm_reboot() { pve_task create "/nodes/$NODE/qemu/$1/status/reboot"; }

# ─── Running inside the VM (qemu-guest-agent) ────────────────────────────────

GUEST_TIMEOUT="${GUEST_TIMEOUT:-60}"
GUEST_OUT=""
GUEST_ERR=""
GUEST_RC=0

# guest_exec VMID cmd [args...] — runs inside the VM (no shell, no eval). Honors --dry-run.
#   Output goes to GUEST_OUT / GUEST_ERR and the real exit code is returned.
#   Configurable timeout: GUEST_TIMEOUT=600 guest_exec ...
#   Data via stdin (never shows up in ps or logs): GUEST_STDIN="user:pass" guest_exec VMID chpasswd
guest_exec() {
  local vmid="$1"
  shift
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '    %s[dry-run]%s VM %s would run: %s\n' "$C_YELLOW" "$C_NC" "$vmid" "$(_fmt_args "$@")" >&2
    GUEST_OUT="" GUEST_ERR="" GUEST_RC=0
    return 0
  fi
  _guest_run "$vmid" "$@"
}

# guest_query VMID cmd [args...] — like guest_exec but also runs in --dry-run (read-only commands only)
guest_query() { _guest_run "$@"; }

# guest_sh VMID 'script' / guest_sh_query VMID 'script' — the same through 'sh -c'
guest_sh()       { guest_exec "$1" sh -c "$2"; }
guest_sh_query() { guest_query "$1" sh -c "$2"; }

_guest_run() {
  local vmid="$1" a res pid st waited=0
  shift
  local -a args=()
  GUEST_OUT="" GUEST_ERR="" GUEST_RC=1
  # Proxmox hangs the qemu-guest-agent (until the VM is rebooted) if an argument contains
  # non-ASCII characters such as ✓ or —. Blocked here; use guest_write_file (base64) for content.
  for a in "$@" "${GUEST_STDIN:-}"; do
    if LC_ALL=C grep -q '[^[:print:][:space:]]' <<<"$a"; then
      GUEST_ERR="Argument with non-ASCII characters: the Proxmox qemu-guest-agent hangs on them (use guest_write_file)"
      log_err "$GUEST_ERR"
      return 1
    fi
  done
  for a in "$@"; do args+=(--command "$a"); done
  [[ -n "${GUEST_STDIN:-}" ]] && args+=(--input-data "$GUEST_STDIN")
  res="$(_PVE_FORCE=1 pve create "/nodes/$NODE/qemu/$vmid/agent/exec" "${args[@]}")" || {
    GUEST_ERR="Could not start the command (agent down?)"
    return 1
  }
  pid="$(json_get 'd.get("pid","")' <<<"$res")"
  [[ -n "$pid" ]] || {
    GUEST_ERR="The agent did not return a PID"
    return 1
  }
  local errf
  errf="$(mktemp)"
  while ((waited < GUEST_TIMEOUT)); do
    st="$(pve get "/nodes/$NODE/qemu/$vmid/agent/exec-status" --pid "$pid" 2>"$errf")" || st=""
    if [[ -z "$st" ]] && grep -q "does not exist" "$errf"; then
      # The qemu-guest-agent restarted (e.g. needrestart during apt) and lost the PID: the
      # command may have succeeded or failed. Wait for the agent to come back and report it.
      rm -f "$errf"
      local i
      for i in $(seq 1 30); do
        _PVE_FORCE=1 pve create "/nodes/$NODE/qemu/$vmid/agent/ping" >/dev/null 2>&1 && break
        sleep 2
      done
      GUEST_ERR="The qemu-guest-agent restarted during the command: result unknown"
      GUEST_RC=125
      return 125
    fi
    if [[ -n "$st" && "$(json_get 'd.get("exited",0)' <<<"$st")" == 1 ]]; then
      rm -f "$errf"
      GUEST_OUT="$(json_get 'u8(d.get("out-data",""))' <<<"$st")"
      GUEST_ERR="$(json_get 'u8(d.get("err-data",""))' <<<"$st")"
      GUEST_RC="$(json_get 'd.get("exitcode",1)' <<<"$st")"
      return "$GUEST_RC"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  rm -f "$errf"
  GUEST_ERR="Timeout (${GUEST_TIMEOUT}s) waiting for PID $pid in VM $vmid"
  GUEST_RC=124
  return 124
}

# guest_exec_detached VMID cmd [args...] — like guest_exec, but the command runs in its own
#   systemd unit (systemd-run), outside the qemu-guest-agent cgroup. Use it for apt/dpkg and
#   installers: if a package restarts the agent, the command does NOT die with it. The exit
#   code is saved to /run/<unit>.rc and collected even if the agent restarted meanwhile.
guest_exec_detached() {
  local vmid="$1"
  shift
  if [[ "$DRY_RUN" == 1 ]]; then
    guest_exec "$vmid" "$@"
    return 0
  fi
  local unit="infra-$$-${RANDOM}" rc=0
  # shellcheck disable=SC2016  # expanded inside the VM
  local wrapper='"$@"; rc=$?; echo "$rc" > "/run/$U.rc"; exit "$rc"'
  _guest_run "$vmid" systemd-run --unit="$unit" --wait --pipe --collect --quiet \
    --setenv=U="$unit" -- sh -c "$wrapper" sh "$@" || rc=$?
  if ((rc != 125)); then
    local o="$GUEST_OUT" e="$GUEST_ERR"
    guest_query "$vmid" rm -f "/run/$unit.rc" >/dev/null 2>&1 || true
    GUEST_OUT="$o" GUEST_ERR="$e" GUEST_RC=$rc
    return "$rc"
  fi
  # The agent restarted: wait for the exit code file
  local out="$GUEST_OUT" waited=0
  while ((waited < GUEST_TIMEOUT)); do
    if guest_query "$vmid" cat "/run/$unit.rc" >/dev/null 2>&1; then
      rc="${GUEST_OUT//[^0-9]/}"
      guest_query "$vmid" rm -f "/run/$unit.rc" >/dev/null 2>&1 || true
      GUEST_OUT="$out"
      GUEST_ERR="(the qemu-guest-agent restarted during the command; output is incomplete)"
      GUEST_RC="${rc:-1}"
      return "$GUEST_RC"
    fi
    sleep 3
    waited=$((waited + 3))
  done
  GUEST_ERR="Timeout (${GUEST_TIMEOUT}s) waiting for unit $unit"
  GUEST_RC=124
  return 124
}

# guest_write_file VMID PATH CONTENT [MODE] — writes a file in the VM (agent/file-write, max ~45 KiB)
guest_write_file() {
  local vmid="$1" path="$2" content="$3" mode="${4:-}"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '    %s[dry-run]%s VM %s would write %s (%s bytes)\n' "$C_YELLOW" "$C_NC" "$vmid" "$path" "${#content}" >&2
    return 0
  fi
  # Base64-encoded here (encode=0): the Proxmox API fails on UTF-8 ("Wide character")
  local b64
  b64="$(printf '%s' "$content" | base64 -w0)"
  ((${#b64} <= 61440)) || {
    log_err "File too large for agent/file-write: $path"
    return 1
  }
  pve create "/nodes/$NODE/qemu/$vmid/agent/file-write" --file "$path" --content "$b64" --encode 0 >/dev/null || return 1
  [[ -z "$mode" ]] || guest_exec "$vmid" chmod "$mode" "$path"
}

# guest_upload VMID LOCAL_FILE REMOTE_PATH [MODE]
#   Files over ~40 KB go gzip + base64 and are decoded inside the VM (agent/file-write limit).
guest_upload() {
  local vmid="$1" src="$2" dest="$3" mode="${4:-}"
  [[ -f "$src" ]] || {
    log_err "$src does not exist"
    return 1
  }
  if (($(wc -c <"$src") <= 40000)); then
    guest_write_file "$vmid" "$dest" "$(cat "$src")"$'\n' "$mode"
    return
  fi
  guest_write_file "$vmid" "$dest.gz.b64" "$(gzip -9c "$src" | base64 -w76)"$'\n' || return 1
  # shellcheck disable=SC2016  # expanded inside the VM
  guest_exec "$vmid" sh -c 'base64 -d "$1.gz.b64" | gunzip > "$1" && rm -f "$1.gz.b64"' sh "$dest" || return 1
  [[ -z "$mode" ]] || guest_exec "$vmid" chmod "$mode" "$dest"
}

# ─── Steps and summary ───────────────────────────────────────────────────────

# step [--warn] "Description" cmd [args...] — prints "Description... [OK]".
#   On failure: [ERROR] (or [WARN] with --warn, which also returns 0) plus the last error lines.
step() {
  local soft=0
  [[ "$1" == --warn ]] && {
    soft=1
    shift
  }
  local desc="$1" rc=0 errf
  shift
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '  %s\n' "$desc"
    "$@" >/dev/null || rc=$?
    return "$rc"
  fi
  printf '  %s... ' "$desc"
  errf="$(mktemp)"
  "$@" >/dev/null 2>"$errf" || rc=$?
  if ((rc == 0)); then
    printf '%s[OK]%s\n' "$C_GREEN" "$C_NC"
  else
    if ((soft)); then
      printf '%s[WARN]%s\n' "$C_YELLOW" "$C_NC"
    else
      printf '%s[ERROR]%s\n' "$C_RED" "$C_NC"
    fi
    { cat "$errf"; printf '%s\n%s\n' "${GUEST_ERR:-}" "${GUEST_OUT:-}"; } | sed '/^[[:space:]]*$/d' | tail -n 5 | sed 's/^/      │ /'
  fi
  rm -f "$errf"
  ((soft)) && return 0
  return "$rc"
}

CURRENT_VMID=""
declare -A _RES_STATE=()
declare -A _RES_MSG=()

# vm_begin VMID — looks the VM up and prints the header. Marks it failed if missing or not QEMU.
vm_begin() {
  CURRENT_VMID="$1"
  if ! vm_locate "$1"; then
    printf '\n%s== VM %s ==%s\n' "$C_BOLD" "$1" "$C_NC"
    vm_fail "does not exist in cluster $CLUSTER_NAME"
    return 1
  fi
  printf '\n%s== VM %s (%s) @ %s ==%s\n' "$C_BOLD" "$1" "$VM_NAME" "$NODE" "$C_NC"
  if [[ "$VM_TYPE" != qemu ]]; then
    vm_fail "is a container ($VM_TYPE), not a QEMU VM"
    return 1
  fi
}

vm_ok() {
  _RES_STATE[$CURRENT_VMID]=OK
  _RES_MSG[$CURRENT_VMID]="${1:-}"
}

vm_fail() {
  _RES_STATE[$CURRENT_VMID]=FAILED
  _RES_MSG[$CURRENT_VMID]="${1:-error}"
  log_err "VM $CURRENT_VMID: ${1:-error}"
}

vm_skip() {
  _RES_STATE[$CURRENT_VMID]=SKIPPED
  _RES_MSG[$CURRENT_VMID]="${1:-}"
  log_warn "VM $CURRENT_VMID: ${1:-skipped}"
}

# summary — final table. Exits 0 if everything went OK, 2 if any VM failed.
summary() {
  local v st fails=0 color
  printf '\n%s== Summary (%s) ==%s\n' "$C_BOLD" "$CLUSTER_NAME" "$C_NC"
  for v in "${VMIDS[@]}"; do
    st="${_RES_STATE[$v]:-FAILED}"
    case "$st" in
      OK) color="$C_GREEN" ;;
      SKIPPED) color="$C_YELLOW" ;;
      *)
        color="$C_RED"
        fails=$((fails + 1))
        ;;
    esac
    printf '  %-6s %s%-8s%s %s\n' "$v" "$color" "$st" "$C_NC" "${_RES_MSG[$v]:-}"
  done
  [[ "$DRY_RUN" == 1 ]] && log_warn "Dry-run mode: nothing was changed"
  ((fails == 0)) && exit 0
  exit 2
}

# ─── host/ scripts ───────────────────────────────────────────────────────────

# run_on_node NODE RELATIVE_SCRIPT [args...] — if we are not on NODE, copies lib/ and host/
# to the node over ssh, runs the script there and exits with its exit code.
# If we are already on NODE (or NODE is empty) it returns without doing anything.
run_on_node() {
  local node="$1" rel="$2"
  shift 2
  [[ -z "$node" || "$node" == "$(hostname -s)" ]] && return 0
  load_cluster
  local addr q
  addr="$(node_address "$node")"
  q="$(printf '%q ' "$@")"
  log_info "Running ${rel} on ${node} (${addr}) over ssh..."
  tar -C "$INFRA_ROOT" -cf - lib host |
    ssh -o BatchMode=yes -o ConnectTimeout=5 "${CLUSTER_USER}@${addr}" \
      "d=\$(mktemp -d) && tar -C \"\$d\" -xf - && bash \"\$d/${rel}\" ${q}; rc=\$?; rm -rf \"\$d\"; exit \$rc"
  exit $?
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Must be run as root"
}

require_pve_node() {
  [[ -d /etc/pve ]] || die "This must run on a Proxmox node (/etc/pve does not exist)"
  require_root
}

# host_run cmd [args...] — runs on the local host; in --dry-run it is only shown
host_run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '    %s[dry-run]%s %s\n' "$C_YELLOW" "$C_NC" "$(_fmt_args "$@")"
    return 0
  fi
  "$@"
}

# host_write FILE CONTENT — writes a host file (with a .bak backup if it existed and changes)
host_write() {
  local f="$1" content="$2"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '    %s[dry-run]%s would write %s:\n' "$C_YELLOW" "$C_NC" "$f"
    # shellcheck disable=SC2001  # prefix every line of a multi-line text
    sed 's/^/      │ /' <<<"$content"
    return 0
  fi
  if [[ -f "$f" ]]; then
    [[ "$(cat "$f")" == "$content" ]] && return 0
    cp -a "$f" "$f.bak"
  fi
  printf '%s\n' "$content" >"$f"
}
