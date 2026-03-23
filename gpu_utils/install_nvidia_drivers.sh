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
echo -e "${YELLOW}[1/9]${NC} Verificando hardware NVIDIA..."
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
echo -e "${YELLOW}[2/9]${NC} Actualizando lista de paquetes..."
apt update
echo -e "${GREEN}✓${NC} Lista de paquetes actualizada"
echo ""

# Paso 3: Instalar dependencias
echo -e "${YELLOW}[3/9]${NC} Instalando dependencias..."
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
echo -e "${YELLOW}[4/9]${NC} Detectando driver recomendado..."
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
echo -e "${YELLOW}[5/9]${NC} Instalando driver NVIDIA ($DRIVER_VERSION)..."
echo "Esto puede tardar varios minutos..."
apt install -y "$DRIVER_VERSION"
echo -e "${GREEN}✓${NC} Driver instalado"
echo ""

# Paso 6: Verificar instalación
echo -e "${YELLOW}[6/9]${NC} Verificando instalación..."
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
echo -e "${YELLOW}[7/9]${NC} Configuración adicional..."

# Crear archivo de configuración para evitar modo de persistencia (opcional)
cat > /etc/modprobe.d/nvidia.conf << EOF
# Configuración NVIDIA
options nvidia NVreg_EnableGpuFirmware=0
EOF

echo -e "${GREEN}✓${NC} Configuración aplicada"
echo ""

# Paso 8: Instalar CUDA Toolkit
echo -e "${YELLOW}[8/9]${NC} Instalando CUDA Toolkit..."
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

# Instalar NVIDIA Container Toolkit (para Docker)
echo -e "${YELLOW}[9/9]${NC} Instalando NVIDIA Container Toolkit..."
echo "Configurando repositorio de NVIDIA..."

# Configurar repositorio
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Actualizar e instalar
apt update
apt install -y nvidia-container-toolkit

# Configurar Docker para usar NVIDIA runtime
if command -v docker > /dev/null 2>&1; then
    echo "Configurando Docker runtime..."
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    echo -e "${GREEN}✓${NC} NVIDIA Container Toolkit instalado y Docker configurado"
else
    echo -e "${YELLOW}⚠${NC} Docker no instalado. Instala Docker y ejecuta:"
    echo "  sudo nvidia-ctk runtime configure --runtime=docker"
    echo "  sudo systemctl restart docker"
fi
echo ""

# Instalar nvtop para monitoreo de GPU
echo -e "${YELLOW}[Extra]${NC} Instalando nvtop para monitoreo de GPU..."
if apt install -y nvtop 2>/dev/null; then
    echo -e "${GREEN}✓${NC} nvtop instalado desde repositorios"
else
    echo -e "${YELLOW}⚠${NC} nvtop no disponible en repositorios, instalando dependencias para compilar..."
    apt install -y cmake libncurses5-dev libncursesw5-dev git
    echo "Para instalar nvtop desde source, ejecuta:"
    echo "  git clone https://github.com/Syllo/nvtop.git"
    echo "  mkdir -p nvtop/build && cd nvtop/build"
    echo "  cmake .. -DNVML_RETRIEVE_HEADER_ONLINE=true"
    echo "  make && sudo make install"
fi
echo ""

# Resumen
echo "=========================================="
echo -e "${GREEN}Instalación completada${NC}"
echo "=========================================="
echo ""
echo "Próximos pasos:"
echo "1. Reinicia el sistema: sudo reboot"
echo "2. Después del reinicio, verifica:"
echo "   - GPU: nvidia-smi"
echo "   - CUDA: nvcc --version"
echo "   - Docker+GPU: docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi"
echo "3. Monitorea GPU con: nvtop"
echo ""
echo "Para verificar sin reiniciar (puede no funcionar):"
echo "  sudo modprobe nvidia"
echo "  nvidia-smi"
echo ""
