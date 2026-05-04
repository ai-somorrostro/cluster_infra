#!/usr/bin/env bash
set -euo pipefail

state_file="/var/lib/iab-expire-cloudinit-password.done"
user_data="/var/lib/cloud/instance/user-data.txt"

if [ -e "${state_file}" ]; then
  exit 0
fi

cloud-init status --wait >/dev/null 2>&1 || true

cloud_user=""
if [ -r "${user_data}" ]; then
  cloud_user="$(
    awk -F: '
      /^[[:space:]]*user:[[:space:]]*/ {
        value=$2
        gsub(/^[[:space:]"'\''-]+|[[:space:]"'\'']+$/, "", value)
        print value
        exit
      }
    ' "${user_data}"
  )"
fi

if [ -z "${cloud_user}" ] || [ "${cloud_user}" = "root" ]; then
  install -d -m 0755 /var/lib
  touch "${state_file}"
  exit 0
fi

if id "${cloud_user}" >/dev/null 2>&1; then
  passwd --expire "${cloud_user}"
fi

touch "${state_file}"
