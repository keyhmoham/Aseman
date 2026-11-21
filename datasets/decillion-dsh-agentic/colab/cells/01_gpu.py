# 1. GPU check
!nvidia-smi
import torch
assert torch.cuda.is_available(), "No GPU: Runtime → Change runtime type → GPU"
GPU = torch.cuda.get_device_name(0)
GPU_MEM_GB = torch.cuda.get_device_properties(0).total_memory / 1e9
print(GPU, f"{GPU_MEM_GB:.0f} GB")
