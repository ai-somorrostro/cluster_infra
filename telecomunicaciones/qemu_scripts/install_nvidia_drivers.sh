#!/bin/bash

# Script para instalar drivers de NVIDIA en Ubuntu Server 24
# GPU: RTX 3070

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "Instalación de drivers NVIDIA"
echo "GPU: RTX 3070 | OS: Ubuntu Server 24"
echo "=========================================="
echo ""

# Verificar que se ejecuta como root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: Este script debe ejecutarse como root${NC}"
    echo "Usa: sudo $0"
    exit 1
fi

# Paso 1: Verificar que la GPU está detectada
echo -e "${YELLOW}[1/8]${NC} Verificando hardware NVIDIA..."
if lspci | grep -i nvidia > /dev/null; then
    echo -e "${GREEN}✓${NC} GPU NVIDIA detectada:"
    lspci | grep -i nvidia
else
    echo -e "${RED}✗${NC} No se detectó GPU NVIDIA. Verifica que:"
    echo "  - La GPU esté correctamente conectada"
    echo "  - El PCI passthrough esté configurado en Proxmox"
    echo "  - La VM tenga acceso al dispositivo"
    exit 1
fi
echo ""

# Paso 2: Actualizar lista de paquetes
echo -e "${YELLOW}[2/8]${NC} Actualizando lista de paquetes..."
apt update
echo -e "${GREEN}✓${NC} Lista de paquetes actualizada"
echo ""

# Paso 3: Instalar dependencias
echo -e "${YELLOW}[3/8]${NC} Instalando dependencias..."
apt install -y \
    build-essential \
    dkms \
    linux-headers-$(uname -r) \
    ubuntu-drivers-common \
    software-properties-common \
    curl \
    wget
echo -e "${GREEN}✓${NC} Dependencias instaladas"
echo ""

# Paso 4: Detectar y recomendar driver
echo -e "${YELLOW}[4/8]${NC} Detectando driver recomendado..."
RECOMMENDED_DRIVER=$(ubuntu-drivers devices | grep -i recommended | awk '{print $3}' | head -1)

if [ -z "$RECOMMENDED_DRIVER" ]; then
    echo -e "${YELLOW}⚠${NC} No se detectó driver recomendado automáticamente"
    echo "Para RTX 3070, usaremos nvidia-driver-535 (o superior)"
    DRIVER_VERSION="nvidia-driver-535"
else
    DRIVER_VERSION="$RECOMMENDED_DRIVER"
    echo -e "${GREEN}✓${NC} Driver recomendado: $DRIVER_VERSION"
fi
echo ""

# Paso 5: Instalar driver
echo -e "${YELLOW}[5/8]${NC} Instalando driver NVIDIA ($DRIVER_VERSION)..."
echo "Esto puede tardar varios minutos..."
apt install -y "$DRIVER_VERSION"
echo -e "${GREEN}✓${NC} Driver instalado"
echo ""

# Paso 6: Verificar instalación
echo -e "${YELLOW}[6/8]${NC} Verificando instalación..."
if nvidia-smi > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Driver funcionando correctamente:"
    nvidia-smi
else
    echo -e "${YELLOW}⚠${NC} nvidia-smi no funciona aún. Puede requerir reinicio."
    echo "Verificando módulos del kernel..."
    lsmod | grep nvidia || echo "Módulos no cargados (normal antes del reinicio)"
fi
echo ""

# Paso 7: Configuración adicional
echo -e "${YELLOW}[7/8]${NC} Configuración adicional..."

# Crear archivo de configuración para evitar modo de persistencia (opcional)
cat > /etc/modprobe.d/nvidia.conf << EOF
# Configuración NVIDIA
options nvidia NVreg_EnableGpuFirmware=0
EOF

echo -e "${GREEN}✓${NC} Configuración aplicada"
echo ""

# Paso 8: Instalar CUDA Toolkit
echo -e "${YELLOW}[8/8]${NC} Instalando CUDA Toolkit..."
echo "Esto puede tardar varios minutos..."
apt install -y nvidia-cuda-toolkit
echo -e "${GREEN}✓${NC} CUDA Toolkit instalado"
echo ""

# Verificar versión de CUDA
if command -v nvcc > /dev/null 2>&1; then
    echo "Versión de CUDA instalada:"
    nvcc --version
    echo ""
fi

# Resumen
echo "=========================================="
echo -e "${GREEN}Instalación completada${NC}"
echo "=========================================="
echo ""
echo "Próximos pasos:"
echo "1. Reinicia el sistema: sudo reboot"
echo "2. Después del reinicio, verifica con: nvidia-smi"
echo "3. Verifica CUDA con: nvcc --version"
echo ""
echo "Para verificar sin reiniciar (puede no funcionar):"
echo "  sudo modprobe nvidia"
echo "  nvidia-smi"
echo ""
