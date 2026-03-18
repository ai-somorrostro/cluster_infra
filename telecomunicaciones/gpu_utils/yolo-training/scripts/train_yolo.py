#!/usr/bin/env python3
"""
Script básico para entrenamiento de YOLO
Descarga automáticamente el modelo si no existe
"""

import os
from ultralytics import YOLO, settings
import torch
from torch.utils.tensorboard import SummaryWriter

def main():
    dataset_path = os.environ.get('DATASET_PATH', '/workspace/dataset')

    # Activar TensorBoard ANTES de crear el modelo
    settings.update({'tensorboard': True, 'runs_dir': '/workspace/runs'})

    # 👇 Los alumnos escriben AQUÍ sus métricas custom de TensorBoard
    tb_writer = SummaryWriter(log_dir="/workspace/runs/forced_tb")
    tb_writer.add_text("status", "tensorboard_enabled", 0)
    tb_writer.flush()
    tb_writer.close()
    
    # Usar YOLOv8 nano (más ligero para pruebas)
    # El modelo se descarga automáticamente si no existe en ~/.cache/ultralytics
    model_name = "yolov8n.pt"
    model = YOLO(model_name)
    
    # Dataset YAML (desde variable de entorno o default)
    dataset_yaml = os.environ.get('DATASET_YAML', '')
    
    if not dataset_yaml:
        print("ERROR: No se especificó DATASET_YAML")
        print("Uso: ./train.sh train_yolo.py dataset config/coco8.yaml")
        exit(1)
    
    # Entrenar el modelo
    results = model.train(
        data=dataset_yaml,
        epochs=10,
        imgsz=640,
        batch=8,
        project='/workspace/runs/detect',
        name='train',
        device=0,
        verbose=True,
        save=True,
        plots=True
    )
    
    print("\n" + "="*60)
    print("Entrenamiento completado!")
    print(f"Resultados guardados en: {results.save_dir}")
    print("="*60)
    
    # Validar el modelo (guardar en /workspace/runs)
    print("\nValidando modelo...")
    metrics = model.val(project="/workspace/runs/detect", name="val")
    print(f"mAP50-95: {metrics.box.map}")
    print(f"mAP50: {metrics.box.map50}")
    

if __name__ == "__main__":
    main()
