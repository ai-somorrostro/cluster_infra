# WireGuard VPN for students (MikroTik)

Generator in `telecomunicaciones/mikrotik_management/wireward_generator/generar_vpn.sh`. It does not act on Proxmox, so it does not use the shared library; it is only documented here.

## What it does

From a `usuarios.txt` file with `user:wireguard_public_key` lines, it generates:

- **`configs/<user>.conf`**: the WireGuard config of each student, with its own `/30` inside `10.10.100.0/24` and the MikroTik public endpoint.
- **`comandos/mikrotik_commands.txt`**: idempotent RouterOS commands that:
  - create the WireGuard interface if missing;
  - give it `10.10.100.1/24`;
  - allow VPN traffic to `192.199.1.0/24`;
  - add one peer per student.

## Usage

```bash
cd telecomunicaciones/mikrotik_management/wireward_generator
# usuarios.txt: first line names the interface, then user:public_key lines
#   # CONFIG: wg-students
#   student01:AbCd...=
./generar_vpn.sh usuarios.txt <mikrotik_public_key> <public_ip> <mikrotik_admin_ip> <port> [first_ip]

ssh admin@<mikrotik_admin_ip> < comandos/mikrotik_commands.txt          # apply
ssh admin@<mikrotik_admin_ip> '/interface wireguard peers print detail' # verify
```

## Secrets

`usuarios.txt`, `configs/`, `comandos/` and `configs.7z` are in `.gitignore`: they hold keys and student data. Send each `configs/<user>.conf` only to its owner.

> The script itself is still in Spanish; translate it next time it is touched (`.cursor/rules/english-code-and-logs.mdc`).
