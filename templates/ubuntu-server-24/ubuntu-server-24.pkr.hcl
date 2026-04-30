packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# ── Proxmox connection ─────────────────────────────────────────────────────────
variable "proxmox_api_url" {
  type = string
}

variable "proxmox_api_token_id" {
  type = string
}

variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}

variable "proxmox_node" {
  type = string
}

# ── VM settings ────────────────────────────────────────────────────────────────
variable "vm_id" {
  type    = number
  default = 9000
}

variable "primary_storage" {
  type    = string
  default = "local-lvm"
}

variable "iso_file" {
  type        = string
  description = "ISO path on Proxmox — format: storage:iso/filename.iso"
}

# ── User ───────────────────────────────────────────────────────────────────────
variable "telecomunicaciones_password" {
  type        = string
  sensitive   = true
  description = "Plaintext password — Packer uses this to SSH in during build"
}

# ──────────────────────────────────────────────────────────────────────────────

source "proxmox-iso" "ubuntu-server-24" {
  proxmox_url              = var.proxmox_api_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  insecure_skip_tls_verify = true

  node    = var.proxmox_node
  vm_id   = var.vm_id
  vm_name = "ubuntu-server-24"
  tags    = "template;ubuntu;ubuntu-24"
  boot    = "order=scsi0;ide2"

  template_description = "Ubuntu Server 24.04 LTS — Packer build {{ isotime \"2006-01-02\" }}"

  boot_iso {
    iso_file = var.iso_file
    unmount  = true
  }

  additional_iso_files {
    cd_files         = ["./http/meta-data", "./http/user-data"]
    cd_label         = "cidata"
    device           = "ide3"
    iso_storage_pool = "local"
  }

  cpu_type = "host"
  cores    = 2
  memory   = 2048

  scsi_controller = "virtio-scsi-pci"

  disks {
    disk_size    = "32G"
    storage_pool = var.primary_storage
    type         = "scsi"
    format       = "raw"
    ssd          = true
    discard      = true
  }

  network_adapters {
    model    = "virtio"
    bridge   = "vmbr0"
    firewall = false
  }

  cloud_init              = true
  cloud_init_storage_pool = var.primary_storage

  boot_wait = "20s"
  boot_command = [
    "e<wait2>",
    "<down><down><down><end>",
    "<bs><bs><bs><bs><bs>",
    " autoinstall cloud-config-url=/dev/null ds=nocloud ---<wait>",
    "<f10>"
  ]

  ssh_username = "telecomunicaciones"
  ssh_password = var.telecomunicaciones_password
  ssh_timeout  = "45m"
  qemu_agent   = true
  task_timeout = "45m"
}

build {
  sources = ["source.proxmox-iso.ubuntu-server-24"]
}
