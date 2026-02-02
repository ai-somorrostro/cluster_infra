#!/bin/bash
# Script para entrenar modelos YOLO

set -e

# Script a ejecutar (default: train_yolo.py)
SCRIPT="${1:-scripts/train_yolo.py}"

echo "Ejecutando entrenamiento: $SCRIPT"
echo "VRAM limit: PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512"
echo "RAM limit: 8GB"
echo ""

docker run --rm \
  --gpus all \
  --network host \
  --memory=8g \
  --user $(id -u):$(id -g) \
  -v $(pwd):/workspace \
  -v $(pwd)/runs:/workspace/runs \
  -v ~/.cache/ultralytics:/root/.cache/ultralytics \
  -e PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512 \
  yolo-training-image \
  python3 /workspace/$SCRIPT
