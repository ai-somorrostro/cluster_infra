#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/games:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

login_user="$(who -m 2>/dev/null | awk '{print $1}' | head -n1)"
login_user="${login_user:-$(logname 2>/dev/null || true)}"
user="${login_user:-${PAM_USER:-${LOGNAME:-${SUDO_USER:-${USER:-$(id -un 2>/dev/null || printf 'user')}}}}}"
hostname_now="$(hostname -s 2>/dev/null || hostname)"
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

if command -v fortune >/dev/null 2>&1 \
  && command -v cowsay >/dev/null 2>&1 \
  && command -v lolcat >/dev/null 2>&1; then
  ( fortune -s | cowsay | lolcat ) 2>/dev/null || true
  printf '\n'
fi

cat <<EOF
Back in ${hostname_now} at IAB cluster, ${user}

If you have any access issues, please contact mikel.diez@somorrostro.com
or open an issue at https://github.com/ai-somorrostro/issues_infra/issues
EOF
