#!/usr/bin/env bash
# vram_killer.sh — Kills the most recent GPU process when the TOTAL VRAM used goes over a limit.
# Runs INSIDE the VM (normally as a systemd service, see install_vram_killer.sh).
#
# No 'set -e' on purpose: this is a monitoring loop and a one-off nvidia-smi failure
# must not take the service down.
set -uo pipefail

LOG_FILE="/var/log/vram_killer.log"

usage() {
  cat <<EOF
Usage: sudo $(basename "$0") [daemon] <limit_MiB> [interval_ms]

Adds up the VRAM of every process using the GPU (MiB, as reported by nvidia-smi)
and, if it goes over the limit, kills (SIGKILL) the most recently started one.

Arguments:
  limit_MiB      Total VRAM allowed (8192 = 8 GiB)
  interval_ms    How often to check (default 5000)

Examples:
  sudo $(basename "$0") 8192            # watch in the foreground
  sudo $(basename "$0") 4096 2000
As a service: sudo ./install_vram_killer.sh <limit_MiB> [interval_ms]
Log: $LOG_FILE
EOF
}

[[ "${1:-}" == daemon ]] && shift
case "${1:-}" in
  "" | -h | --help) usage; exit 0 ;;
esac

LIMIT_MIB="${1}"
INTERVAL_MS="${2:-5000}"
[[ "$LIMIT_MIB" =~ ^[0-9]+$ && "$INTERVAL_MS" =~ ^[0-9]+$ ]] || { echo "Error: limit and interval must be numbers" >&2; exit 1; }
LIMIT_MIB=$((10#$LIMIT_MIB))
INTERVAL_MS=$((10#$INTERVAL_MS))
((LIMIT_MIB > 0 && INTERVAL_MS > 0)) || { echo "Error: limit and interval must be > 0" >&2; exit 1; }
INTERVAL_S="$(awk "BEGIN {printf \"%.3f\", $INTERVAL_MS / 1000}")"

[[ "$(id -u)" -eq 0 ]] || { echo "Error: must run as root (to be able to kill processes)" >&2; exit 1; }
command -v nvidia-smi >/dev/null || { echo "Error: nvidia-smi not available (NVIDIA drivers installed?)" >&2; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

kill_process() {
  local pid="$1" vram="$2" cmd
  cmd="$(ps -p "$pid" -o cmd= 2>/dev/null | head -c 100)"
  log "KILLING PID $pid - VRAM ${vram} MiB - CMD: $cmd"
  kill -9 "$pid" 2>/dev/null || true
  sleep 1
  if ps -p "$pid" >/dev/null 2>&1; then
    log "ERROR: process $pid is still alive"
  else
    log "OK: process $pid terminated"
  fi
}

log "Start - total limit ${LIMIT_MIB} MiB - interval ${INTERVAL_MS} ms - the most recent process gets killed"

while true; do
  # pid,vram_mib,start (epoch of the /proc/<pid> directory)
  procs=()
  while IFS=',' read -r pid vram; do
    pid="${pid//[[:space:]]/}"
    vram="${vram//[[:space:]]/}"
    [[ "$pid" =~ ^[0-9]+$ && "$vram" =~ ^[0-9]+$ ]] || continue
    start="$(stat -c %Y "/proc/$pid" 2>/dev/null)" || continue
    procs+=("$pid,$vram,$start")
  done < <(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null)

  if ((${#procs[@]} > 0)); then
    total=0
    latest_pid="" latest_vram=0 latest_start=-1
    for p in "${procs[@]}"; do
      IFS=',' read -r pid vram start <<<"$p"
      total=$((total + vram))
      if ((start > latest_start)); then
        latest_pid="$pid" latest_vram="$vram" latest_start="$start"
      fi
    done
    log "GPU processes: ${#procs[@]} | Total VRAM: ${total} / ${LIMIT_MIB} MiB"
    if ((total > LIMIT_MIB)); then
      log "WARNING: limit exceeded (${total} > ${LIMIT_MIB} MiB)"
      if [[ -n "$latest_pid" ]]; then
        kill_process "$latest_pid" "$latest_vram"
      else
        log "ERROR: could not identify the process to kill"
      fi
    fi
  fi
  sleep "$INTERVAL_S"
done
