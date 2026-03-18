#!/bin/bash
# Descarga el dataset COCO8 para pruebas

set -e

DATASET_DIR="datasets/coco8"

echo "Descargando COCO8 dataset..."
echo "Destino: $DATASET_DIR"
echo ""

# Crear directorio
mkdir -p "$DATASET_DIR"

# Descargar dataset
cd "$DATASET_DIR"

if [ ! -f "coco8.zip" ]; then
    echo "Descargando coco8.zip..."
    wget -q --show-progress https://github.com/ultralytics/assets/releases/download/v0.0.0/coco8.zip
else
    echo "coco8.zip ya existe, omitiendo descarga"
fi

# Extraer
if [ ! -d "coco8" ]; then
    echo "Extrayendo..."
    unzip -q coco8.zip
    echo "✓ Extraído"
else
    echo "Dataset ya extraído"
fi

cd ../..

echo ""
echo "✓ Dataset descargado en: $DATASET_DIR/coco8"
echo ""
echo "Estructura:"
ls -la "$DATASET_DIR/coco8"
echo ""
echo "Uso:"
echo "  ./train.sh scripts/train_yolo.py $DATASET_DIR/coco8"
