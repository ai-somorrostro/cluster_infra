#!/usr/bin/env bash
# vm_mig_bench.sh — runs one workload in many MIG + LXD containers at once and measures it
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/pve_common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <command> CONFIG [args]

Load test for a VM set up with vm_mig_lxd.sh: the same workload (for example the
notebooks of a course) runs in many containers at the same moment, each on its own
MIG slice, while the VM samples VRAM per slice, RAM per container, GPU temperature,
power and clocks, and the VM's CPU and RAM. The config is a TOML file
(config/bench/<name>.toml, see config/bench/example.toml).

The workload is prepared once in the VM (/opt/mig-bench/<name>, mounted read-only in
the containers); each run copies it to /root/mig-bench/<name>/work in every container.
The users' /home is never touched.

Commands:
  check CONFIG              Validate CONFIG (local, no VM)
  prepare CONFIG            Upload [source.files], clone, run [setup] and the warm-up
  run CONFIG -s SCENARIO    Run the items in the selected containers at once
      --containers A,B|all  Containers (default: all managed ones that are running)
      --gpu N               Only containers on GPU N
      --count N             Only the first N (ordered by GPU and slice)
      --interval SEC        Sampling interval (default 3)
      --stagger SEC         Start container k after k*SEC seconds (default 0: all at once)
      --no-gpu-sampling     Do not run nvidia-smi during the run (containers and VM only)
  report RESULT.json...     Print results again; a 1-container run is the baseline
  clean CONFIG              Remove the mounts, work dirs and /opt/mig-bench/<name>

Results are saved in config/bench/results/ (gitignored: they name the containers).

Common options:
  -c, --cluster N   Target cluster (default: .env / config/clusters.conf)
  -n, --dry-run     Show what would be done
  -y, --yes         Do not ask for confirmation
  -h, --help        This help

Examples:
  $(basename "$0") prepare config/bench/rag-s2.toml
  $(basename "$0") run config/bench/rag-s2.toml -s gpu --containers lab-profe
  $(basename "$0") run config/bench/rag-s2.toml -s gpu
  $(basename "$0") report config/bench/results/*rag-s2-gpu*.json
EOF
}

ENGINE="$INFRA_ROOT/guest/mig_bench.py"
STAGE=/var/lib/mig-bench/staging
RESULTS="$INFRA_ROOT/config/bench/results"
CMD=""
POS=()
RARGS=()

while (($# > 0)); do
  case "$1" in
    -s | --scenario) need_value "$1" "${2:-}"; RARGS+=(--scenario "$2"); shift 2 ;;
    --no-gpu-sampling) RARGS+=("$1"); shift ;;
    --containers | --gpu | --count | --interval | --stagger) need_value "$1" "${2:-}"; RARGS+=("$1" "$2"); shift 2 ;;
    -h | --help | -n | --dry-run | -y | --yes | -c | --cluster) parse_common_opt "$@"; shift "$COMMON_SHIFT" ;;
    -*) die_usage "Unknown option: $1" ;;
    *) if [[ -z "$CMD" ]]; then CMD="$1"; else POS+=("$1"); fi; shift ;;
  esac
done
[[ -n "$CMD" ]] || { usage; exit 1; }

# ─── Helpers ─────────────────────────────────────────────────────────────────

# toml_get CONFIG EXPR — evaluates a Python expression on the parsed TOML (d)
toml_get() {
  python3 -c 'import sys,tomllib,os; d=tomllib.load(open(sys.argv[1],"rb")); print(eval(sys.argv[2]))' "$1" "$2"
}

# open_vm CONFIG — locates the VM of CONFIG, checks the agent and uploads engine + config
open_vm() {
  local vm
  vm="$(toml_get "$1" 'd.get("vm","")')"
  [[ "$vm" =~ ^[0-9]+$ ]] || die_usage "No VM: use 'vm = <id>' in $1"
  VMIDS=("$vm")
  prepare_run none
  VMID="$vm"
  vm_begin "$VMID" || summary
  vm_require_agent "$VMID" || { vm_fail "VM stopped or without qemu-guest-agent"; summary; }
  local machine
  machine="$(json_get 'd.get("machine","")' <<<"$(vm_config "$VMID")")"
  [[ "$machine" != *viommu=* ]] ||
    log_warn "machine '$machine' has a vIOMMU: concurrent CUDA processes will fail (see docs/mig.md, Troubleshooting)"
  local d="$DRY_RUN"
  DRY_RUN=0
  step "Staging dir" guest_exec "$VMID" mkdir -p "$STAGE" || { vm_fail "cannot write in the VM"; summary; }
  step "Upload engine" guest_upload "$VMID" "$ENGINE" "$STAGE/mig_bench.py" 0755 || { vm_fail "cannot upload the engine"; summary; }
  step "Upload config" guest_upload "$VMID" "$1" "$STAGE/$NAME.toml" 0600 || { vm_fail "cannot upload the config"; summary; }
  DRY_RUN="$d"
}

# upload_files CONFIG — sends every [source.files] entry to /var/lib/mig-bench/<name>/files/<dest>
upload_files() {
  local dest src dir="/var/lib/mig-bench/$NAME/files"
  while IFS=$'\t' read -r dest src; do
    [[ -n "$dest" ]] || continue
    src="${src/#\~/$HOME}"
    [[ "$src" == /* ]] || src="$(dirname "$(readlink -f "$1")")/$src"   # relative to the config file
    [[ -f "$src" ]] || { log_err "[source.files] $dest: $src does not exist"; return 1; }
    guest_exec "$VMID" mkdir -p "$(dirname "$dir/$dest")" || return 1
    step "Upload $dest ($(du -h "$src" | cut -f1))" guest_upload "$VMID" "$src" "$dir/$dest" 0600 || return 1
  done < <(toml_get "$1" '"\n".join(f"{k}\t{v}" for k,v in (d.get("source",{}).get("files") or {}).items())')
}

# bench_run ARGS... — runs the engine detached in the VM (systemd-run) and streams its log.
#   Sets RESULT_PATH from the engine's "RESULT <path>" line.
bench_run() {
  local unit log off=0 rc="" waited=0 out
  unit="mig-bench-$(date +%s)"
  log="/var/log/mig-bench/$unit.log"
  RESULT_PATH=""
  # shellcheck disable=SC2016  # expanded inside the VM
  guest_exec "$VMID" sh -c 'mkdir -p /var/log/mig-bench && systemd-run --unit="$1" --collect --quiet \
    sh -c "python3 $2 $3 > $4 2>&1; echo \$? > $4.rc"' sh "$unit" "$STAGE/mig_bench.py" "$*" "$log" ||
    { log_err "could not start the engine: $GUEST_ERR"; return 1; }
  _show() {
    printf '%s' "$1" | grep -v '^RESULT ' | sed 's/^/  │ /'
    local r
    r="$(printf '%s' "$1" | sed -n 's/^RESULT //p' | tail -1)"
    [[ -z "$r" ]] || RESULT_PATH="$r"
  }
  while :; do
    sleep 5
    waited=$((waited + 5))
    # The END marker keeps the trailing newline (command substitution strips it) so the offset is exact
    if guest_query "$VMID" sh -c "tail -c +$((off + 1)) '$log' 2>/dev/null; printf END" >/dev/null 2>&1; then
      out="${GUEST_OUT%END}"
      off=$((off + $(printf '%s' "$out" | wc -c)))
      [[ -z "$out" ]] || _show "$out"
    fi
    if guest_query "$VMID" cat "$log.rc" >/dev/null 2>&1; then
      rc="${GUEST_OUT//[^0-9]/}"
      if guest_query "$VMID" sh -c "tail -c +$((off + 1)) '$log'; printf END" >/dev/null 2>&1; then
        out="${GUEST_OUT%END}"
        [[ -z "$out" ]] || _show "$out"
      fi
      break
    fi
    ((waited < 6 * 3600)) || { log_err "timeout waiting for the engine (log in the VM: $log)"; return 124; }
  done
  log_info "Log in the VM: $log"
  return "${rc:-1}"
}

# fetch_result — copies RESULT_PATH from the VM to config/bench/results/
fetch_result() {
  [[ -n "$RESULT_PATH" ]] || return 0
  local f
  f="$RESULTS/$(basename "$RESULT_PATH")"
  mkdir -p "$RESULTS"
  GUEST_TIMEOUT=120 guest_query "$VMID" sh -c "gzip -c '$RESULT_PATH' | base64 -w0" >/dev/null || return 1
  (umask 077 && printf '%s' "$GUEST_OUT" | base64 -d | gunzip >"$f") || return 1
  log_ok "Result saved: ${f#"$INFRA_ROOT"/}"
}

# ─── Commands ────────────────────────────────────────────────────────────────

if [[ "$CMD" == report ]]; then
  ((${#POS[@]} > 0)) || die_usage "report RESULT.json..."
  python3 "$ENGINE" report "${POS[@]}"
  exit
fi

CFG="${POS[0]:-}"
[[ -n "$CFG" && -f "$CFG" ]] || die_usage "$CMD requires an existing CONFIG file"
python3 "$ENGINE" check "$CFG" >/dev/null || { python3 "$ENGINE" check "$CFG"; exit 2; }
NAME="$(toml_get "$CFG" 'd["name"]')"

case "$CMD" in
  check)
    python3 "$ENGINE" check "$CFG"
    ;;

  prepare)
    open_vm "$CFG"
    if [[ "$DRY_RUN" == 1 ]]; then vm_ok "dry-run: would upload [source.files] and run prepare"; summary; fi
    upload_files "$CFG" || { vm_fail "cannot upload [source.files]"; summary; }
    rc=0
    bench_run prepare "$STAGE/$NAME.toml" || rc=$?
    fetch_result || log_warn "could not download the warm-up result"
    if ((rc == 0)); then vm_ok "prepared"; else vm_fail "prepare failed (rc $rc)"; fi
    summary
    ;;

  run)
    [[ " ${RARGS[*]} " == *" --scenario "* ]] || die_usage "run requires -s SCENARIO"
    open_vm "$CFG"
    if [[ "$DRY_RUN" == 1 ]]; then vm_ok "dry-run: would run ${RARGS[*]}"; summary; fi
    confirm "Run benchmark '$NAME' (${RARGS[*]}) in VM $VMID ($VM_NAME)? Users in those containers will notice the load" ||
      { vm_skip "cancelled"; summary; }
    rc=0
    bench_run run "$STAGE/$NAME.toml" "${RARGS[@]}" || rc=$?
    fetch_result || log_warn "could not download the result"
    if ((rc == 0)); then vm_ok "benchmark done"; else vm_fail "run failed (rc $rc)"; fi
    summary
    ;;

  clean)
    open_vm "$CFG"
    if [[ "$DRY_RUN" == 1 ]]; then vm_ok "dry-run: would remove mounts, work dirs and /opt/mig-bench/$NAME"; summary; fi
    confirm "Remove benchmark '$NAME' from VM $VMID ($VM_NAME)?" || { vm_skip "cancelled"; summary; }
    rc=0
    bench_run clean "$STAGE/$NAME.toml" || rc=$?
    if ((rc == 0)); then vm_ok "cleaned"; else vm_fail "clean failed (rc $rc)"; fi
    summary
    ;;

  *) die_usage "Unknown command: $CMD" ;;
esac
