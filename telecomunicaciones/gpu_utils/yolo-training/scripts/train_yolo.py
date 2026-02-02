#!/usr/bin/env python3
"""
Script básico para entrenamiento de YOLO
Descarga automáticamente el modelo si no existe
"""

import os
from ultralytics import YOLO
import torch

def main():
    # Mostrar información de CUDA
    print(f"PyTorch version: {torch.__version__}")
    print(f"CUDA available: {torch.cuda.is_available()}")
    print(f"CUDA version: {torch.version.cuda}")
    print(f"Number of GPUs: {torch.cuda.device_count()}")
    
    if torch.cuda.is_available():
        for i in range(torch.cuda.device_count()):
            print(f"GPU {i}: {torch.cuda.get_device_name(i)}")
            # Mostrar memoria disponible
            total_mem = torch.cuda.get_device_properties(i).total_memory / 1024**3
            print(f"  Total memory: {total_mem:.2f} GB")
    
    print("\n" + "="*60)
    print("Iniciando entrenamiento YOLO")
    print("="*60 + "\n")
    
    # Usar YOLOv8 nano (más ligero para pruebas)
    # El modelo se descarga automáticamente si no existe en ~/.cache/ultralytics
    model_name = "yolov8n.pt"
    print(f"Cargando modelo: {model_name}")
    model = YOLO(model_name)
    
    # Dataset de ejemplo: COCO8 (dataset pequeño para pruebas)
    # Se descarga automáticamente
    print("\nEntrenando con dataset COCO8 (pequeño, para pruebas)...")
    print("Parámetros:")
    print("  - Epochs: 10")
    print("  - Image size: 640")
    print("  - Batch: 8")
    print("  - Device: GPU (si está disponible)")
    print("\nLos resultados se guardarán en /workspace/runs/detect/trainX")
    print("="*60 + "\n")
    
    # Entrenar el modelo
    results = model.train(
        data='coco8.yaml',  # Dataset de ejemplo (se descarga automáticamente)
        epochs=10,           # Pocas épocas para prueba rápida
        imgsz=640,           # Tamaño de imagen
        batch=8,             # Batch size (ajustar según VRAM)
        project='/workspace/runs/detect',  # Donde guardar resultados
        name='train',        # Nombre del experimento
        device=0,            # Usar GPU 0 (automático si solo hay una)
        verbose=True,        # Mostrar progreso detallado
        save=True,           # Guardar checkpoints
        plots=True           # Generar gráficos
    )
    
    print("\n" + "="*60)
    print("Entrenamiento completado!")
    print(f"Resultados guardados en: {results.save_dir}")
    print("="*60)
    
    # Validar el modelo
    print("\nValidando modelo...")
    metrics = model.val()
    print(f"mAP50-95: {metrics.box.map}")
    print(f"mAP50: {metrics.box.map50}")
    
    print("\n¡Listo! Puedes ver los resultados con TensorBoard:")
    print("  docker run --rm --network host -v $(pwd)/runs:/workspace/runs yolo-training-image tensorboard --logdir=/workspace/runs --port=6006")

if __name__ == "__main__":
    main()
