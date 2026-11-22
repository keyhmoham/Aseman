# 2. Install the training stack, pinned, without touching Kaggle's CUDA build of PyTorch.
# A constraints file pins torch to the version that is already installed, so no package can upgrade it.
import subprocess, sys
torch_version = subprocess.run([sys.executable, '-c', 'import torch; print(torch.__version__)'],
                               capture_output=True, text=True).stdout.strip()
open('/tmp/constraints.txt', 'w').write(f'torch=={torch_version}\n')
print('keeping torch', torch_version)
!pip install -q -c /tmp/constraints.txt transformers==5.24.0 peft==0.22.0 accelerate==1.16.0 datasets==5.2.0 \
    bitsandbytes==0.50.2 huggingface_hub==2.4.0 safetensors==0.8.0 jsonschema openai requests psutil

# Optional fast kernels for the Gated DeltaNet (linear attention) layers, 24 of the 32. Without them Transformers uses
# its reference PyTorch implementation: correct, but slower. Triton kernels are not guaranteed on Turing (T4, sm75),
# so they are tested here on the GPU and removed again if they fail or disagree.
INSTALL_FAST_KERNELS = True
if INSTALL_FAST_KERNELS:
    !pip install -q -c /tmp/constraints.txt flash-linear-attention==0.6.0
    test = r'''
import torch
from fla.ops.gated_delta_rule import chunk_gated_delta_rule, fused_recurrent_gated_delta_rule
torch.manual_seed(0)
B, T, H, K = 1, 512, 4, 128
dev, dt = 'cuda', torch.float16
q, k, v = (torch.randn(B, T, H, K, device=dev, dtype=dt, requires_grad=True) for _ in range(3))
g = (-torch.rand(B, T, H, device=dev) * 0.1).requires_grad_()
beta = torch.rand(B, T, H, device=dev, dtype=dt).requires_grad_()
o1, _ = chunk_gated_delta_rule(q, k, v, g=g, beta=beta, use_qk_l2norm_in_kernel=True)
o1.float().pow(2).mean().backward()
with torch.no_grad():
    o2, _ = fused_recurrent_gated_delta_rule(q, k, v, g=g, beta=beta, use_qk_l2norm_in_kernel=True)
err = (o1.float() - o2.float()).abs().max().item() / (o2.float().abs().max().item() + 1e-6)
grads_ok = all(t.grad is not None and torch.isfinite(t.grad).all() for t in (q, k, v, g, beta))
assert torch.isfinite(o1).all() and grads_ok and err < 2e-2, f'mismatch {err}, grads ok {grads_ok}'
print('fla kernels OK on', torch.cuda.get_device_name(0), f'(relative difference {err:.1e})')
'''
    open('/tmp/fla_test.py', 'w').write(test)
    r = subprocess.run([sys.executable, '/tmp/fla_test.py'], capture_output=True, text=True)
    print((r.stdout or '') + (r.stderr or '')[-1500:])
    if r.returncode != 0:
        print('fast kernels unusable here: uninstalling, training will use the PyTorch reference path')
        !pip uninstall -q -y flash-linear-attention fla-core
print('Restart the kernel only if pip reports that torch itself changed (it should not).')
