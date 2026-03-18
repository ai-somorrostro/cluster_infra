#!/bin/bash
# Script para lanzar TensorBoard

set -e

# Puerto (default: 6006)
PORT="${1:-6006}"

echo "Lanzando TensorBoard en puerto $PORT"
echo "Accede en: http://localhost:$PORT"
echo "Presiona Ctrl+C para detener"
echo ""

docker run --rm \
  --network host \
  -v $(pwd)/runs:/workspace/runs \
  yolo-training-image \
  python -m tensorboard.main --logdir=/workspace/runs --port=$PORT --host=0.0.0.0
