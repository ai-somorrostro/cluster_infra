# Proxmox API
proxmox_api_url          = "https://192.168.136.238:8006/api2/json"
proxmox_api_token_id     = "root@pam!infra"
proxmox_api_token_secret = "YOUR_API_TOKEN_SECRET"

proxmox_node = "kalimdor"
vm_id        = 9000

primary_storage = "local-lvm"
iso_file        = "ssd-data:iso/ubuntu-24.04.3-live-server-amd64.iso"

ssh_username      = "telecomunicaciones"
ssh_password      = "YOUR_PLAINTEXT_BUILD_PASSWORD"
ssh_password_hash = "$6$REPLACE_WITH_SHA512_HASH"
ssh_public_key    = "ssh-ed25519 AAAA... user@host"

# Optional. Leave empty unless Packer chooses the wrong source IP for its HTTP server.
http_bind_address = ""
