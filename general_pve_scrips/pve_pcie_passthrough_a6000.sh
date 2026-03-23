#!/bin/bash

# pve_pcie_passthrough_a6000.sh - Prepara el host Proxmox para PCIe passthrough de RTX A6000
# GPU: NVIDIA RTX A6000 (GA102GL, 48GB)
# Ejecutar en el host Proxmox como root. Requiere reboot al terminar.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error:${NC} Ejecuta como root en el host Proxmox"
  exit 1
fi

echo ""
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN} PCIe Passthrough HOST SETUP — RTX A6000${NC}"
echo -e "${CYAN}==========================================${NC}"

# ─── Paso 1: Detectar IDs de todas las A6000 (y su audio companion) ──────────

echo -e "\n${YELLOW}[1/5]${NC} Detectando GPUs RTX A6000..."

mapfile -t GPU_LINES < <(lspci -nn | grep -i "RTX A6000" || true)
if [ ${#GPU_LINES[@]} -eq 0 ]; then
  echo -e "${RED}[✗]${NC} No se encontró ninguna RTX A6000 en este nodo."
  echo "    Verifica con: lspci | grep -i nvidia"
  exit 1
fi

echo -e "${GREEN}[✓]${NC} Encontradas ${#GPU_LINES[@]} GPU(s):"
for line in "${GPU_LINES[@]}"; do echo "    ${line}"; done

# Extraer vendor:device IDs únicos (GPU + audio)
declare -A SEEN_IDS
ALL_IDS_LIST=()

for line in "${GPU_LINES[@]}"; do
  SLOT=$(echo "$line" | awk '{print $1}')
  GPU_ID=$(echo "$line" | grep -oP '\[[\da-fA-F]{4}:[\da-fA-F]{4}\]' | tr -d '[]' | head -1)
  if [[ -n "$GPU_ID" && -z "${SEEN_IDS[$GPU_ID]:-}" ]]; then
    SEEN_IDS[$GPU_ID]=1
    ALL_IDS_LIST+=("$GPU_ID")
  fi
  # Audio companion (.1 del mismo slot)
  SLOT_BASE="${SLOT%.*}"
  AUDIO_LINE=$(lspci -nn -s "${SLOT_BASE}.1" 2>/dev/null | head -1 || true)
  if [[ -n "$AUDIO_LINE" ]]; then
    AUDIO_ID=$(echo "$AUDIO_LINE" | grep -oP '\[[\da-fA-F]{4}:[\da-fA-F]{4}\]' | tr -d '[]' | head -1)
    if [[ -n "$AUDIO_ID" && -z "${SEEN_IDS[$AUDIO_ID]:-}" ]]; then
      SEEN_IDS[$AUDIO_ID]=1
      ALL_IDS_LIST+=("$AUDIO_ID")
      echo "    Audio: ${AUDIO_LINE}"
    fi
  fi
done

ALL_IDS=$(IFS=','; echo "${ALL_IDS_LIST[*]}")
echo -e "${GREEN}[✓]${NC} IDs para vfio-pci: ${ALL_IDS}"

# ─── Paso 2: IOMMU ───────────────────────────────────────────────────────────

echo -e "\n${YELLOW}[2/5]${NC} Configurando IOMMU (AMD EPYC)..."

IOMMU_FLAG="amd_iommu=on iommu=pt"

if grep -qE 'amd_iommu' /proc/cmdline 2>/dev/null; then
  echo -e "${GREEN}[✓]${NC} IOMMU ya activo"
elif [[ -f /etc/kernel/cmdline ]]; then
  # proxmox-boot-tool (ZFS)
  CMDLINE=$(cat /etc/kernel/cmdline)
  echo "${CMDLINE} ${IOMMU_FLAG}" > /etc/kernel/cmdline
  proxmox-boot-tool refresh
  echo -e "${GREEN}[✓]${NC} Añadido a /etc/kernel/cmdline + proxmox-boot-tool refresh"
else
  # GRUB
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 '"${IOMMU_FLAG}"'"/' /etc/default/grub
  update-grub
  echo -e "${GREEN}[✓]${NC} Añadido a /etc/default/grub + update-grub"
fi

# ─── Paso 3: Módulos VFIO ────────────────────────────────────────────────────

echo -e "\n${YELLOW}[3/5]${NC} Configurando módulos VFIO..."

for mod in vfio vfio_iommu_type1 vfio_pci; do
  if ! grep -q "^${mod}$" /etc/modules 2>/dev/null; then
    echo "$mod" >> /etc/modules
    echo -e "${GREEN}[✓]${NC} Añadido: ${mod}"
  else
    echo -e "${GREEN}[✓]${NC} Ya presente: ${mod}"
  fi
done

echo "options vfio-pci ids=${ALL_IDS}" > /etc/modprobe.d/vfio-pci-a6000.conf
echo -e "${GREEN}[✓]${NC} /etc/modprobe.d/vfio-pci-a6000.conf → ids=${ALL_IDS}"

if [[ ! -f /etc/modprobe.d/kvm.conf ]] || ! grep -q "ignore_msrs" /etc/modprobe.d/kvm.conf; then
  echo "options kvm ignore_msrs=1 report_ignored_msrs=0" > /etc/modprobe.d/kvm.conf
  echo -e "${GREEN}[✓]${NC} /etc/modprobe.d/kvm.conf"
else
  echo -e "${GREEN}[✓]${NC} kvm.conf ya configurado"
fi

# ─── Paso 4: Blacklist NVIDIA en el host ─────────────────────────────────────

echo -e "\n${YELLOW}[4/5]${NC} Blacklisteando drivers NVIDIA en el host..."

cat > /etc/modprobe.d/blacklist-nvidia-host.conf << 'EOF'
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
blacklist nvidia_modeset
EOF
echo -e "${GREEN}[✓]${NC} /etc/modprobe.d/blacklist-nvidia-host.conf"

# ─── Paso 5: Actualizar initramfs ────────────────────────────────────────────

echo -e "\n${YELLOW}[5/5]${NC} Actualizando initramfs..."
update-initramfs -u -k all
echo -e "${GREEN}[✓]${NC} initramfs actualizado"

# ─── Resumen ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN} Host configurado — necesitas reiniciar${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo -e "${CYAN}Tras el reboot, verifica:${NC}"
echo "  lspci -nnk | grep -A3 'RTX A6000'   # debe mostrar vfio-pci como driver"
echo "  dmesg | grep -i iommu               # debe mostrar IOMMU habilitado"
echo ""
echo -e "${CYAN}Después asigna la GPU desde la GUI de Proxmox:${NC}"
echo "  VM → Hardware → Add → PCI Device → selecciona la A6000"
echo ""
echo -n "¿Reiniciar ahora? [s/N]: "
read -r resp
if [[ "${resp,,}" == "s" ]]; then
  reboot
else
  echo "Reinicia manualmente: reboot"
fi
