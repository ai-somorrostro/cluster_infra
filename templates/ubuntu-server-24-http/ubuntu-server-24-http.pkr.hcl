packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.5"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

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
  description = "ISO path on Proxmox, e.g. storage:iso/ubuntu-24.04.3-live-server-amd64.iso"
}

variable "ssh_username" {
  type    = string
  default = "telecomunicaciones"
}

variable "ssh_password" {
  type      = string
  sensitive = true
}

variable "ssh_password_hash" {
  type      = string
  sensitive = true
}

variable "ssh_public_key" {
  type        = string
  description = "Public key installed by autoinstall for the build user"
}

variable "http_bind_address" {
  type    = string
  default = ""
}

source "proxmox-iso" "ubuntu-server-24-http" {
  proxmox_url              = var.proxmox_api_url
  username                 = var.proxmox_api_token_id
  token                    = var.proxmox_api_token_secret
  insecure_skip_tls_verify = true

  node    = var.proxmox_node
  vm_id   = var.vm_id
  vm_name = "ubuntu-server-24-http"
  tags    = "template;ubuntu;ubuntu-24"
  boot    = "order=scsi0;ide2"

  template_description = "Ubuntu Server 24.04 LTS HTTP autoinstall - Packer build {{ isotime \"2006-01-02\" }}"

  boot_iso {
    iso_file = var.iso_file
    type     = "ide"
    index    = "2"
    unmount  = true
  }

  http_bind_address = var.http_bind_address
  http_content = {
    "/meta-data" = file("${path.root}/http/meta-data")
    "/user-data" = templatefile("${path.root}/http/user-data.pkr.tpl", {
      ssh_username      = var.ssh_username
      ssh_password_hash = var.ssh_password_hash
      ssh_public_key    = var.ssh_public_key
    })
  }

  boot_wait = "20s"
  boot_command = [
    "e<wait2>",
    "<down><down><down><end>",
    "<bs><bs><bs><bs><bs>",
    " autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<wait>",
    "<f10>"
  ]

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

  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "45m"
  qemu_agent   = true
  task_timeout = "45m"
}

build {
  sources = ["source.proxmox-iso.ubuntu-server-24-http"]

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    scripts = [
      "scripts/install-packages.sh",
      "scripts/configure-system.sh",
      "scripts/install-docker.sh",
      "scripts/install-uv.sh",
    ]
  }

  provisioner "file" {
    source      = "../../motds/iab-cluster.sh"
    destination = "/tmp/10-iab-cluster"
  }

  provisioner "file" {
    source      = "../../motds/banner.txt"
    destination = "/tmp/iab-banner.txt"
  }

  provisioner "shell" {
    inline = [
      "sudo install -d -o root -g root -m 0755 /etc/iab-cluster",
      "sudo install -o root -g root -m 0644 /tmp/iab-banner.txt /etc/iab-cluster/banner.txt",
      "sudo install -o root -g root -m 0755 /tmp/10-iab-cluster /etc/update-motd.d/10-iab-cluster",
      "sudo find /etc/update-motd.d ! -name 10-iab-cluster -exec chmod -x {} +",
      "if [ -f /etc/default/motd-news ]; then sudo sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news; fi",
      "sudo rm -f /tmp/10-iab-cluster /tmp/iab-banner.txt",
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    scripts         = ["scripts/cleanup.sh"]
  }
}
