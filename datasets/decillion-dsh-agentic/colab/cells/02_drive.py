# 2. Google Drive: checkpoints, logs and the final model live here
from google.colab import drive
drive.mount('/content/drive')
import os
OUT_DIR = '/content/drive/MyDrive/decillion-qwen35-4b'
os.makedirs(OUT_DIR, exist_ok=True)
print('outputs →', OUT_DIR)
