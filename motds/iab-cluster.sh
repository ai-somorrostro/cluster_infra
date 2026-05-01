#!/usr/bin/env bash
set -euo pipefail

login_user="$(who -m 2>/dev/null | awk '{print $1}' | head -n1)"
login_user="${login_user:-$(logname 2>/dev/null || true)}"
user="${login_user:-${PAM_USER:-${LOGNAME:-${SUDO_USER:-${USER:-$(id -un 2>/dev/null || printf 'user')}}}}}"
hostname_now="$(hostname -s 2>/dev/null || hostname)"
date_now="$(TZ=Europe/Madrid date '+%Y-%m-%d %H:%M:%S %Z')"
ram_usage="$(free -h | awk '/^Mem:/ {print $3 " / " $2}')"
disk_usage="$(df -h / | awk 'NR==2 {print $3 " / " $2}')"
banner_file="/etc/iab-cluster/banner.txt"
ips="$(
  ip -o -4 addr show scope global 2>/dev/null \
    | awk '{split($4, a, "/"); print a[1]}' \
    | paste -sd ', ' -
)"

if [ -z "${ips}" ]; then
  ips="no IPv4 address"
fi

cat <<EOF

EOF

if [ -r "${banner_file}" ]; then
  cat "${banner_file}"
  printf '\n'
fi

cat <<EOF
Back in ${hostname_now} at IAB cluster, ${user}


Date: ${date_now}
RAM:  ${ram_usage}
Disk: ${disk_usage}
IPs:  ${ips}
If you got any issues, please contact mikel.diez@somorrostro.com
EOF
