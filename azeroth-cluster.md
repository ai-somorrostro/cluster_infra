# Cluster Proxmox — Azeroth

## Nodos

| Nodo | IP | CPU | RAM |
|---|---|---|---|
| `kalimdor` | 192.168.136.238 | 2x AMD EPYC | 256 GB |
| `eastkingdoms` | 192.168.136.226 | 2x AMD EPYC | 256 GB |
| `northrend` | 192.168.136.178 | 2x AMD EPYC | 256 GB |

## Almacenamiento

| Storage | Tipo | Nodos | Disco | Uso |
|---|---|---|---|---|
| `local-lvm` | LVM-Thin | cada nodo (local) | NVMe sistema | VMs + Containers |
| `nvme-vms` | LVM-Thin | los 3 nodos | NVMe secundario (1.5T) | VMs + Containers rápidas |
| `ssd-vms` | LVM-Thin | los 3 nodos | SSD ATA #1 (3.6T) | VMs + Containers |
| `ssd-data` | NFS (kalimdor) | los 3 nodos | SSD ATA #2 (3.6T) | ISOs, templates, backups |
| *(libres)* | — | kalimdor | SSD ATA #3 y #4 (3.6T c/u) | Reservados para Ceph |

> `ssd-data` está exportado por NFS desde `kalimdor` y montado en `/mnt/ssd-data` en los 3 nodos.

## Convenciones

- **Plantillas de VMs** → almacenadas en `ssd-data` (disponibles en todos los nodos)

## Pendiente

- Configurar **Ceph** con los discos `sdc` y `sdd` de cada nodo para almacenamiento distribuido y HA.
