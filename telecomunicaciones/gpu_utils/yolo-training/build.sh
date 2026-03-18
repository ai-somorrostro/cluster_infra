#!/bin/bash
# Script para construir la imagen Docker
# Uso: ./build.sh [--no-cache]

set -e

# Opciones de build
BUILD_OPTS=""
if [ "$1" == "--no-cache" ]; then
    echo "Construyendo sin caché..."
    BUILD_OPTS="--no-cache"
fi

echo "Construyendo imagen yolo-training-image..."
docker build $BUILD_OPTS -t yolo-training-image .

echo ""
echo "✓ Imagen construida exitosamente"
echo ""
echo "Comandos disponibles:"
echo "  ./train.sh              - Entrenar con script básico"
echo "  ./train.sh mi_script.py - Entrenar con tu script"
echo "  ./tensorboard.sh [PORT] - Lanzar TensorBoard (default: 6006)"
echo "  ./shell.sh              - Modo interactivo"
