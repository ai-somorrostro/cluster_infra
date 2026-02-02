#!/bin/bash
# Script para entrar en modo interactivo

set -e

echo "Entrando en modo interactivo..."
echo "Directorio: /workspace"
echo ""

docker run -it \
  --gpus all \
  --network host \
  --memory=8g \
  --user $(id -u):$(id -g) \
  -v $(pwd):/workspace \
  -v $(pwd)/runs:/workspace/runs \
  -v ~/.cache/ultralytics:/root/.cache/ultralytics \
  -e PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512 \
  yolo-training-image \
  /bin/bash
