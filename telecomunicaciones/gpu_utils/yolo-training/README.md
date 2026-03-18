# YOLO Training Docker Environment



## 1. Construir la Imagen

```bash
cd gpu_utils
docker build -t yolo-training-image .
```

O usa el script:
```bash
./build.sh
```

## 2. Entrenar un Modelo

### Uso básico

```bash
./train.sh <script_entrenamiento> <carpeta_imagenes>
```

### Ejemplos

**Entrenamiento básico (script de prueba):**
```bash
./train.sh
# Usa: scripts/train_yolo.py y datasets/
```

**Con tu propio script y dataset:**
```bash
./train.sh scripts/mi_train.py datasets/mi_dataset
```

**Con path absoluto a imágenes:**
```bash
./train.sh scripts/mi_train.py /mnt/data/imagenes
```

**Ver ayuda:**
```bash
./train.sh --help
```

### Acceso desde el script Python

Dentro de tu script de entrenamiento, las carpetas están montadas en:
- Script: El que especificaste (path absoluto)
- Dataset: `/workspace/dataset` (montado desde tu carpeta_imagenes)
- Output: `/workspace/runs` (persistente en gpu_utils/yolo-training/runs)
- Cache: `/root/.cache/ultralytics` (modelos YOLO descargados)

### Opción C: Modo interactivo (para debugging)

```bash
./shell.sh
```

## 3. Visualizar con TensorBoard

### Usuario 1 (puerto 6006)

```bash
./tensorboard.sh
```

### Usuario 2 (puerto 6007)

```bash
./tensorboard.sh 6007
```

### Usuario 3 (puerto 6008)

```bash
./tensorboard.sh 6008
```

Luego accede en tu navegador a: `http://localhost:6006` (o el puerto que hayas elegido)

## Parámetros Explicados

- `--gpus all`: Usa todas las GPUs disponibles
- `--network host`: Usa la red del host (simplifica acceso a tensorboard)
- `--memory=8g`: Limita RAM del contenedor a 8GB
- `--user $(id -u):$(id -g)`: Ejecuta como tu usuario (evita problemas de permisos)
- `-v $(pwd):/workspace`: Monta directorio actual en /workspace
- `-v $(pwd)/runs:/workspace/runs`: Monta runs (resultados persistentes)
- `-v ~/.cache/ultralytics:/root/.cache/ultralytics`: Cachea modelos YOLO (compartido)
- `-e PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512`: Limita fragmentación de VRAM

## Usar GPU Específica

Si quieres usar solo una GPU específica (ej: GPU 0):

```bash
docker run --rm \
  --gpus '"device=0"' \
  --network host \
  --memory=8g \
  --user $(id -u):$(id -g) \
  -v $(pwd):/workspace \
  -v $(pwd)/runs:/workspace/runs \
  -v ~/.cache/ultralytics:/root/.cache/ultralytics \
  -e PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512 \
  yolo-training-image \
  python3 /workspace/scripts/train_yolo.py
```

## Modelos Disponibles

Los modelos YOLO se descargan automáticamente de Ultralytics:
- `yolov8n.pt` - Nano (más rápido, menos preciso)
- `yolov8s.pt` - Small
- `yolov8m.pt` - Medium
- `yolov8l.pt` - Large
- `yolov8x.pt` - Extra Large (más lento, más preciso)

Se cachean en `~/.cache/ultralytics` y se comparten entre contenedores.

## Datasets de Ejemplo

El script básico usa `coco8.yaml` (dataset pequeño para pruebas rápidas).

Para usar tus propios datasets:
1. Colócalos en `datasets/`
2. Crea un archivo YAML de configuración
3. Modifica el script para usar tu dataset

## Troubleshooting

### Error de permisos en runs/
Si tienes problemas de permisos, asegúrate de usar `--user $(id -u):$(id -g)`

### Out of Memory
- Reduce `batch` en el script de entrenamiento
- Usa un modelo más pequeño (yolov8n en lugar de yolov8x)
- Verifica que `PYTORCH_CUDA_ALLOC_CONF` esté configurado

### TensorBoard no accesible
- Verifica que uses `--network host`
- Verifica que el puerto no esté en uso: `netstat -tuln | grep 6006`
