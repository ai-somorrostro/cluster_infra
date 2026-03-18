#!/bin/bash
# Script para entrenar modelos YOLO
# Uso: ./train.sh [--detach] [script] [dataset_dir] [dataset_yaml] [env_file]

set -e

# Detectar flag --detach
DETACH_MODE=false
if [ "$1" == "--detach" ] || [ "$1" == "-d" ]; then
    DETACH_MODE=true
    shift
fi

# Help
if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "Uso: $0 [--detach] [script] [dataset_dir] [dataset_yaml] [env_file]"
    echo ""
    echo "Flags:"
    echo "  --detach, -d - Ejecutar en background (detached mode)"
    echo ""
    echo "Argumentos:"
    echo "  script       - Script Python a ejecutar (default: scripts/train_yolo.py)"
    echo "  dataset_dir  - Directorio con images/ y labels/ (default: datasets)"
    echo "  dataset_yaml - Archivo YAML de configuración del dataset"
    echo "  env_file     - Archivo con variables de entorno (default: .env)"
    echo ""
    echo "Variables de entorno:"
    echo "  DOCKER_IMAGE - Nombre de la imagen Docker (default: yolo-training-image)"
    echo ""
    echo "Ejemplos:"
    echo "  $0"
    echo "  $0 --detach scripts/train_yolo.py datasets/coco8/coco8 config/coco8.yaml"
    echo "  $0 -d scripts/train_yolo.py datasets/coco8/coco8 config/coco8.yaml"
    echo ""
    exit 0
fi

# Parámetros
SCRIPT="${1:-scripts/train_yolo.py}"
DATASET_DIR="${2:-datasets}"
DATASET_YAML="${3:-}"
ENV_FILE="${4:-.env}"
DOCKER_IMAGE="${DOCKER_IMAGE:-yolo-training-image}"

echo "Script:      $SCRIPT"
echo "Dataset:     $DATASET_DIR"
echo "YAML:        ${DATASET_YAML:-none}"
echo "Env file:    ${ENV_FILE}"
echo "Image:       $DOCKER_IMAGE"
echo "VRAM limit:  7GB (max_split_size_mb:7168)"
echo "RAM limit:   4GB"
echo ""

# Crear directorios con permisos correctos
mkdir -p runs/detect
chmod -R 777 runs

# Caché compartida para modelos YOLO
SHARED_CACHE="/opt/ultralytics-cache"
if [ ! -d "$SHARED_CACHE" ]; then
    echo "Creando caché compartida en $SHARED_CACHE (necesita sudo)"
    sudo mkdir -p "$SHARED_CACHE"
    sudo chmod 777 "$SHARED_CACHE"
fi

# Construir comando docker
if [ "$DETACH_MODE" = true ]; then
    CONTAINER_NAME="yolo-train-$(date +%s)"
    DOCKER_FLAGS="-d --name $CONTAINER_NAME"
    echo "Modo detached: contenedor '$CONTAINER_NAME'"
else
    DOCKER_FLAGS="--rm"
fi

DOCKER_CMD="docker run $DOCKER_FLAGS \
  --gpus all \
  --network host \
  --memory=4g \
  --shm-size=2g \
  --user $(id -u):$(id -g) \
  -v $(pwd):/workspace \
  -v $(pwd)/runs:/workspace/runs \
  -v $(pwd)/$DATASET_DIR:/workspace/dataset \
  -v $SHARED_CACHE:/.cache/ultralytics \
  -e HOME=/ \
  -e PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:7168 \
  -e DATASET_YAML=\"$DATASET_YAML\""


DOCKER_CMD="$DOCKER_CMD $DOCKER_IMAGE python3 /workspace/$SCRIPT"

eval $DOCKER_CMD

if [ "$DETACH_MODE" = true ]; then
    echo ""
    echo "✓ Entrenamiento iniciado en background"
    echo "Ver logs:    docker logs -f $CONTAINER_NAME"
    echo "Detener:     docker stop $CONTAINER_NAME"
    echo "Eliminar:    docker rm $CONTAINER_NAME"
fi
