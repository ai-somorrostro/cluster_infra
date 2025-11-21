#!/bin/bash
# Uso: ./generar_vpn.sh usuarios.txt <clave_publica_mikrotik> <ip_publica> <ip_admin> <puerto> [ip_inicial]

[[ "$#" -lt 5 ]] && { echo "Uso: $0 usuarios.txt pubkey_mikrotik ip_publica ip_admin puerto [ip_inicial]"; exit 1; }

USUARIOS="$1"
MK_PUB="$2"
MK_IP_PUBLICA="$3"  # Para Endpoint en configs (62.99.99.232)
MK_IP_ADMIN="$4"    # Para SSH (192.199.1.1)
MK_PORT="$5"
IP_START="${6:-2}"  # Default 2 si no se especifica

# Leer nombre del interface desde usuarios.txt (primera línea: # CONFIG: nombre)
WG_INTERFACE=$(grep "^# CONFIG:" "$USUARIOS" | head -1 | cut -d: -f2- | tr -d ' ')
[[ -z "$WG_INTERFACE" ]] && { echo "Error: Falta '# CONFIG: interface_name' en $USUARIOS"; exit 1; }

mkdir -p configs comandos

echo "# Comandos MikroTik" > comandos/mikrotik_commands.txt
echo "" >> comandos/mikrotik_commands.txt
echo "# Crear interface si no existe (ignora error si ya existe)" >> comandos/mikrotik_commands.txt
echo ":if ([:len [/interface wireguard find name=\"$WG_INTERFACE\"]] = 0) do={/interface wireguard add name=$WG_INTERFACE listen-port=$MK_PORT comment=\"Auto-generado\"}" >> comandos/mikrotik_commands.txt
echo "" >> comandos/mikrotik_commands.txt
echo "# Configurar IP del interface (ignora si ya existe)" >> comandos/mikrotik_commands.txt
echo ":if ([:len [/ip address find address=\"10.10.100.1/24\" interface=\"$WG_INTERFACE\"]] = 0) do={/ip address add address=10.10.100.1/24 interface=$WG_INTERFACE}" >> comandos/mikrotik_commands.txt
echo "" >> comandos/mikrotik_commands.txt
echo "# Permitir acceso a red 192.199.1.0/24 (ignora si ya existe)" >> comandos/mikrotik_commands.txt
echo ":if ([:len [/ip firewall filter find comment=\"VPN acceso red local\"]] = 0) do={/ip firewall filter add chain=forward src-address=10.10.100.0/24 dst-address=192.199.1.0/24 action=accept place-before=0 comment=\"VPN acceso red local\"}" >> comandos/mikrotik_commands.txt
echo "" >> comandos/mikrotik_commands.txt
echo "# Añadir peers" >> comandos/mikrotik_commands.txt

IP=$IP_START

while IFS=: read -r USER PUB || [[ -n "$USER" ]]; do
    [[ -z "$USER" || "$USER" =~ ^# ]] && continue
    
    USER=$(echo "$USER" | tr -d ' ')
    PUB=$(echo "$PUB" | tr -d ' ')
    
    BASE=$((($IP / 4) * 4))
    ADDR="10.10.100.$((BASE + 2))/30"
    ALLOWED="10.10.100.$BASE/30"
    
    echo "/interface wireguard peers add name=\"$USER\" interface=$WG_INTERFACE public-key=\"$PUB\" allowed-address=$ALLOWED persistent-keepalive=25s" >> comandos/mikrotik_commands.txt
    
    cat > "configs/${USER}.conf" << EOF
[Interface]
PrivateKey = YOUR_PRIVATE_KEY_HERE
Address = $ADDR
DNS = 8.8.8.8

[Peer]
PublicKey = $MK_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = $MK_IP_PUBLICA:$MK_PORT
PersistentKeepalive = 21
EOF
    
    echo "✓ $USER -> $ADDR (Peer: $PUB)"
    IP=$((IP + 4))
done < "$USUARIOS"

echo -e "\n=== RESUMEN ==="
echo "Configs generados: configs/"
echo "Comandos MikroTik: comandos/mikrotik_commands.txt"
echo -e "\n=== APLICAR EN MIKROTIK ==="
echo "ssh admin@$MK_IP_ADMIN < comandos/mikrotik_commands.txt"
echo -e "\n=== VERIFICAR PEERS CREADOS ==="
echo "ssh admin@$MK_IP_ADMIN '/interface wireguard peers print detail'"
