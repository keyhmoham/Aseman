# 1. Hardware check. nvidia-smi is used instead of torch.cuda, so this kernel opens no CUDA context and holds no
# GPU memory while the training processes run.
import os, shutil, subprocess
import psutil

os.environ['PYTORCH_CUDA_ALLOC_CONF'] = 'expandable_segments:True'  # inherited by the training processes
os.environ['TOKENIZERS_PARALLELISM'] = 'false'

gpus = subprocess.run(['nvidia-smi', '--query-gpu=name,memory.total,memory.used,compute_cap', '--format=csv,noheader'],
                      capture_output=True, text=True).stdout.strip().splitlines()
for i, g in enumerate(gpus):
    print(f'GPU {i}: {g}')
NUM_GPUS = len(gpus)
if NUM_GPUS != 2:
    raise RuntimeError(f'Expected 2 GPUs, found {NUM_GPUS}. Choose Accelerator → GPU T4 ×2.')
ram = psutil.virtual_memory()
print(f'RAM: total {ram.total / 2**30:.1f} GiB, available {ram.available / 2**30:.1f} GiB, CPUs {os.cpu_count()}')
for path in ('/kaggle/working', '/tmp'):
    du = shutil.disk_usage(path)
    print(f'disk {path}: {du.free / 1e9:.0f} GB free of {du.total / 1e9:.0f} GB')
