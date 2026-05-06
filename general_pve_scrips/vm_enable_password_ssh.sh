#!/bin/bash

# vm_enable_password_ssh.sh - Fuerza habilitar password SSH

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/pve-load-env.sh"

if [ $# -lt 2 ]; then
    echo "Uso: $0 <nodo> <vmid>"
    exit 1
fi

NODE=$1
VMID=$2

echo "Habilitando password SSH en VM $VMID..."

# Backup
pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "cp" --command "/etc/ssh/sshd_config" --command "/etc/ssh/sshd_config.bak" >/dev/null 2>&1

# Modificar con sed múltiples líneas
pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sh" --command "-c" --command "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config && sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config" >/dev/null 2>&1

# Añadir al final si no existe
pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sh" --command "-c" --command "grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config" >/dev/null 2>&1

# Verificar sintaxis
echo -n "Verificando sintaxis... "
OUT=$(pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "sshd" --command "-t" --output-format json 2>&1 | grep -oP '"pid":\K[0-9]+')
sleep 1
STATUS=$(pvesh get /nodes/$NODE/qemu/$VMID/agent/exec-status --pid $OUT --output-format json 2>&1 | grep -oP '"exitcode":\K[0-9]+')

if [ "$STATUS" == "0" ]; then
    echo "OK"
else
    echo "ERROR"
    exit 1
fi

# Reiniciar SSH
echo -n "Reiniciando SSH... "
pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "systemctl" --command "restart" --command "sshd" >/dev/null 2>&1
sleep 2
pvesh create /nodes/$NODE/qemu/$VMID/agent/exec --command "systemctl" --command "restart" --command "ssh" >/dev/null 2>&1
sleep 2
echo "OK"

echo "Completado. Prueba: ssh usuario@IP"

