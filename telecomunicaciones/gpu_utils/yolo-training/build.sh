#!/bin/bash
# Script para construir la imagen Docker

set -e

echo "Construyendo imagen yolo-training-image..."
docker build -t yolo-training-image .

echo ""
echo "✓ Imagen construida exitosamente"
echo ""
echo "Comandos disponibles:"
echo "  ./train.sh              - Entrenar con script básico"
echo "  ./train.sh mi_script.py - Entrenar con tu script"
echo "  ./tensorboard.sh [PORT] - Lanzar TensorBoard (default: 6006)"
echo "  ./shell.sh              - Modo interactivo"
