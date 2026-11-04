#!/usr/bin/env bash
# vm_mig_lxd.sh — MIG + LXD configurator for GPU VMs (GPU slices per container, users, SSH)
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <command> [args]

Carves the A800/A100 GPUs of a VM with MIG and gives each LXD container inside
the VM its own GPU slice, its users and SSH access. The desired state lives in a
TOML file (config/mig/<name>.toml, see config/mig/example.toml); 'plan' shows
what would change and 'apply' makes it real. Checks RAM, disk and CPU first.

Commands:
  configure CONFIG [VMID]   Interactive wizard: writes/edits CONFIG, then runs plan
  plan CONFIG [--prune]     Validate + resource checks + diff (changes nothing)
  apply CONFIG [--prune]    Plan, confirm, apply. --prune deletes containers that are
                            not in CONFIG (their /home is archived in the VM first)
  status [CONFIG|VMID]      GPUs, MIG slices and containers of the VM
  passwd CONFIG CONTAINER USER   New temporary password for a user
  layouts                   Full MIG layouts of an A800/A100 40GB

The VM comes from 'vm = <id>' in CONFIG (or --vm ID). New passwords are printed
and appended to CONFIG's .credentials file (mode 600, gitignored).

Script options:
  --vm ID           VM to act on (overrides 'vm' in CONFIG)
  --prune           See apply

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -n, --dry-run     apply only shows the plan
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") layouts
  $(basename "$0") configure config/mig/gpu2.toml 106
  $(basename "$0") plan config/mig/gpu2.toml
  $(basename "$0") apply config/mig/gpu2.toml
  $(basename "$0") passwd config/mig/gpu2.toml lab-ana ana
EOF
}

ENGINE="$INFRA_ROOT/guest/mig_lxd.py"
WIZARD="$INFRA_ROOT/vm/mig_wizard.py"
STAGE=/var/lib/mig-lxd/staging
CMD=""
VM_OPT=""
PRUNE=0
POS=()

while (($# > 0)); do
  case "$1" in
    --vm) need_value "$1" "${2:-}"; VM_OPT="$2"; shift 2 ;;
    --prune) PRUNE=1; shift ;;
    -h | --help | -n | --dry-run | -y | --yes | -c | --cluster) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
    -*) die_usage "Unknown option: $1" ;;
    *) if [[ -z "$CMD" ]]; then CMD="$1"; else POS+=("$1"); fi; shift ;;
  esac
done
[[ -n "$CMD" ]] || { usage; exit 1; }

# ─── Helpers ─────────────────────────────────────────────────────────────────

toml_vm() {
  python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb")).get("vm",""))' "$1" 2>/dev/null
}

# resolve_vm [CONFIG] — sets VMIDS from --vm, a VMID argument or 'vm' in CONFIG
resolve_vm() {
  local cfg="${1:-}" id="$VM_OPT"
  if [[ -z "$id" && -n "$cfg" && -f "$cfg" ]]; then id="$(toml_vm "$cfg")"; fi
  if [[ -z "$id" && "$cfg" =~ ^[0-9]+$ ]]; then id="$cfg"; fi
  [[ "$id" =~ ^[0-9]+$ ]] || die_usage "No VM: use 'vm = <id>' in the config or --vm ID"
  VMIDS=("$id")
}

# open_vm — locates the VM, checks the agent and uploads the engine
open_vm() {
  prepare_run none
  VMID="${VMIDS[0]}"
  vm_begin "$VMID" || summary
  vm_require_agent "$VMID" || { vm_fail "VM stopped or without qemu-guest-agent"; summary; }
  local cfgj balloon memory
  cfgj="$(vm_config "$VMID")"
  memory="$(json_get 'd.get("memory","")' <<<"$cfgj")"
  balloon="$(json_get 'd.get("balloon","")' <<<"$cfgj")"
  if [[ -n "$balloon" && "$balloon" != 0 && "$balloon" -lt "${memory:-0}" ]]; then
    log_warn "Proxmox ballooning is on (min ${balloon} MiB < ${memory} MiB): the VM can get less RAM than the checks assume"
  fi
  # The engine is staged on every run (also with -n: it only reads in plan/status)
  local d="$DRY_RUN"
  DRY_RUN=0
  step "Staging dir" guest_exec "$VMID" mkdir -p "$STAGE" || { vm_fail "cannot write in the VM"; summary; }
  step "Upload engine" guest_upload "$VMID" "$ENGINE" "$STAGE/mig_lxd.py" 0755 || { vm_fail "cannot upload the engine"; summary; }
  DRY_RUN="$d"
}

upload_config() {
  local d="$DRY_RUN"
  DRY_RUN=0
  guest_upload "$VMID" "$1" "$STAGE/config.toml" 0600 || { DRY_RUN="$d"; return 1; }
  DRY_RUN="$d"
}

# engine_query ARGS... — runs a read-only engine command and prints its output
engine_query() {
  local rc=0
  GUEST_TIMEOUT=300 guest_query "$VMID" python3 "$STAGE/mig_lxd.py" "$@" || rc=$?
  printf '%s' "$GUEST_OUT"
  [[ -z "$GUEST_ERR" ]] || printf '%s\n' "$GUEST_ERR" >&2
  return "$rc"
}

# engine_run ARGS... — runs a long engine command detached in the VM and streams its log
engine_run() {
  local unit log off=0 rc="" waited=0 out
  unit="mig-lxd-$(date +%s)"
  log="/var/log/mig-lxd/$unit.log"
  # shellcheck disable=SC2016  # expanded inside the VM
  guest_exec "$VMID" sh -c 'mkdir -p /var/log/mig-lxd && systemd-run --unit="$1" --collect --quiet \
    sh -c "python3 $2 $3 > $4 2>&1; echo \$? > $4.rc"' sh "$unit" "$STAGE/mig_lxd.py" "$*" "$log" ||
    { log_err "could not start the engine: $GUEST_ERR"; return 1; }
  while :; do
    sleep 4
    waited=$((waited + 4))
    if guest_query "$VMID" sh -c "tail -c +$((off + 1)) '$log' 2>/dev/null" >/dev/null 2>&1 && [[ -n "$GUEST_OUT" ]]; then
      out="$GUEST_OUT"
      off=$((off + $(printf '%s' "$out" | wc -c)))
      printf '%s' "$out" | grep -v '^MIGLXD_CREDENTIALS_JSON ' | sed 's/^/  │ /'
      printf '%s' "$out" | grep '^MIGLXD_CREDENTIALS_JSON ' >>"$CREDS_TMP" || true
    fi
    if guest_query "$VMID" cat "$log.rc" >/dev/null 2>&1; then
      rc="${GUEST_OUT//[^0-9]/}"
      # last bytes written between the two reads
      guest_query "$VMID" sh -c "tail -c +$((off + 1)) '$log'" >/dev/null 2>&1 &&
        { printf '%s' "$GUEST_OUT" | grep -v '^MIGLXD_CREDENTIALS_JSON ' | sed 's/^/  │ /'
          printf '%s' "$GUEST_OUT" | grep '^MIGLXD_CREDENTIALS_JSON ' >>"$CREDS_TMP" || true; }
      break
    fi
    ((waited < 7200)) || { log_err "timeout waiting for the engine (log in the VM: $log)"; return 124; }
  done
  log_info "Log in the VM: $log"
  return "${rc:-1}"
}

# save_creds CONFIG — appends new credentials to CONFIG.credentials (mode 600)
save_creds() {
  local f="${1%.toml}.credentials"
  [[ -s "$CREDS_TMP" ]] || return 0
  (umask 077 && touch "$f")
  python3 - "$CREDS_TMP" "$f" <<'EOF'
import json, sys, datetime
rows = []
for line in open(sys.argv[1]):
    rows += json.loads(line.split(" ", 1)[1])
with open(sys.argv[2], "a") as f:
    for r in rows:
        f.write(f"{datetime.date.today()}  {r['container']:<16} {r['user']:<14} {r['password']:<16} {r['ssh']}\n")
EOF
  log_ok "Credentials appended to $f"
}

# restart_vm_and_wait — Proxmox reboot (full QEMU restart, resets the passthrough GPUs)
restart_vm_and_wait() {
  local i up
  log_info "Restarting VM $VMID..."
  vm_reboot "$VMID" >/dev/null || return 1
  sleep 20
  for i in $(seq 1 60); do
    if GUEST_TIMEOUT=10 guest_query "$VMID" cut -d. -f1 /proc/uptime >/dev/null 2>&1; then
      up="${GUEST_OUT//[^0-9]/}"
      ((${up:-9999} < 900)) && { log_ok "VM back (uptime ${up}s)"; sleep 15; return 0; }
    fi
    sleep 5
  done
  return 1
}

CREDS_TMP="$(mktemp)"
trap 'rm -f "$CREDS_TMP"' EXIT

# ─── Commands ────────────────────────────────────────────────────────────────

case "$CMD" in
  layouts)
    python3 "$ENGINE" layouts
    ;;

  status)
    resolve_vm "${POS[0]:-}"
    open_vm
    engine_query status || { vm_fail "status failed"; summary; }
    vm_ok "status"
    summary
    ;;

  plan | apply)
    CFG="${POS[0]:-}"
    [[ -n "$CFG" && -f "$CFG" ]] || die_usage "$CMD requires an existing CONFIG file"
    resolve_vm "$CFG"
    open_vm
    step "Upload config" upload_config "$CFG" || { vm_fail "cannot upload the config"; summary; }
    PARGS=(plan "$STAGE/config.toml")
    ((PRUNE)) && PARGS+=(--prune)
    echo
    rc=0
    engine_query "${PARGS[@]}" || rc=$?
    echo
    if ((rc == 3)); then vm_fail "the config does not pass the checks (see above)"; summary; fi
    if ((rc != 0)); then vm_fail "plan failed (rc $rc)"; summary; fi
    if [[ "$CMD" == plan || "$DRY_RUN" == 1 ]]; then vm_ok "plan only"; summary; fi
    if grep -q "^  No changes\.$" <<<"$GUEST_OUT"; then vm_ok "no changes"; summary; fi
    confirm "Apply these changes to VM $VMID ($VM_NAME)?" || { vm_skip "cancelled"; summary; }
    AARGS=(apply "$STAGE/config.toml")
    ((PRUNE)) && AARGS+=(--prune)
    rc=0
    engine_run "${AARGS[@]}" || rc=$?
    if ((rc == 4)); then
      # MIG mode changes are applied by a VM restart (Proxmox resets the GPU; an in-guest reset breaks it)
      echo
      if confirm "MIG mode change pending: restart VM $VMID ($VM_NAME) now and continue?"; then
        restart_vm_and_wait || { vm_fail "the VM did not come back"; summary; }
        step "Upload engine" guest_upload "$VMID" "$ENGINE" "$STAGE/mig_lxd.py" 0755 || true
        step "Upload config" upload_config "$CFG" || true
        rc=0
        engine_run "${AARGS[@]}" || rc=$?
      else
        save_creds "$CFG"
        vm_skip "restart the VM and run apply again"
        summary
      fi
    fi
    save_creds "$CFG"
    if ((rc == 0)); then vm_ok "applied"; else vm_fail "apply failed (rc $rc)"; fi
    summary
    ;;

  passwd)
    ((${#POS[@]} == 3)) || die_usage "passwd CONFIG CONTAINER USER"
    resolve_vm "${POS[0]}"
    open_vm
    [[ "$DRY_RUN" == 1 ]] && { vm_ok "dry-run"; summary; }
    rc=0
    out="$(GUEST_TIMEOUT=120 guest_exec "$VMID" python3 "$STAGE/mig_lxd.py" passwd "${POS[1]}" "${POS[2]}" && printf '%s' "$GUEST_OUT")" || rc=$?
    grep -v '^MIGLXD_CREDENTIALS_JSON ' <<<"$out" || true
    grep '^MIGLXD_CREDENTIALS_JSON ' <<<"$out" >>"$CREDS_TMP" || true
    [[ -f "${POS[0]}" ]] && save_creds "${POS[0]}"
    if ((rc == 0)); then vm_ok "password reset"; else vm_fail "passwd failed: $GUEST_ERR"; fi
    summary
    ;;

  configure)
    CFG="${POS[0]:-}"
    [[ -n "$CFG" ]] || die_usage "configure requires a CONFIG path (it is created if missing)"
    [[ -n "${POS[1]:-}" ]] && VM_OPT="${POS[1]}"
    resolve_vm "$CFG"
    command -v whiptail >/dev/null || die "whiptail is not installed (apt install whiptail)"
    open_vm
    state="$(mktemp)"
    engine_query state >"$state" || { vm_fail "could not read the VM state"; summary; }
    python3 "$WIZARD" --state "$state" --vm "$VMID" --vm-name "$VM_NAME" "$CFG" || { rm -f "$state"; vm_skip "wizard cancelled"; summary; }
    rm -f "$state"
    log_ok "Config written: $CFG"
    step "Upload config" upload_config "$CFG" || { vm_fail "cannot upload the config"; summary; }
    echo
    rc=0
    engine_query plan "$STAGE/config.toml" || rc=$?
    echo
    if ((rc == 0)); then vm_ok "config ready: $(basename "$0") apply $CFG"; else vm_fail "the config does not pass the checks"; fi
    summary
    ;;

  *) die_usage "Unknown command: $CMD" ;;
esac
