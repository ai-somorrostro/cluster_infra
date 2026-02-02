# Dockerfile para entrenamiento YOLO y DINO
# Base: CUDA 11.8 con cuDNN 8
FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04

# Evitar prompts interactivos
ENV DEBIAN_FRONTEND=noninteractive

# Instalar dependencias del sistema
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    git \
    wget \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Actualizar pip
RUN python3 -m pip install --upgrade pip

# Instalar PyTorch con CUDA 11.8 (versión 2.1.0 es estable con CUDA 11.8)
RUN pip3 install torch==2.1.0 torchvision==0.16.0 torchaudio==2.1.0 --index-url https://download.pytorch.org/whl/cu118

# Instalar librerías para YOLO y DINO
RUN pip3 install \
    ultralytics \
    opencv-python-headless \
    transformers \
    supervision \
    groundingdino-py \
    tensorboard \
    matplotlib \
    pillow \
    pyyaml \
    tqdm

# Variables de entorno para limitar VRAM
ENV PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512

# Crear directorio de trabajo
WORKDIR /workspace

# Configurar usuario (se pasará en runtime)
# El contenedor correrá como el usuario del host para evitar problemas de permisos

# Exponer puerto para tensorboard (configurable)
EXPOSE 6006

# Por defecto, bash
CMD ["/bin/bash"]
