#!/usr/bin/env python3
"""Merge the trained LoRA adapter into a 16-bit copy of the base model, for vLLM.

    python3 merge_lora.py --config /kaggle/working/run_config.json

Runs on the CPU (the base model in fp16 is ~9 GB of host RAM), so it works right after training without
touching GPU memory. The adapter is applied to the full-precision base, not to the 4-bit one it was
trained against (the standard QLoRA export). The result keeps the full Qwen3.5 architecture, vision tower
included, so vLLM loads it like the base model. Processor and chat-template files are copied from the base.
"""
import argparse, json, os, shutil, sys

import torch
from huggingface_hub import snapshot_download
from peft import PeftModel
from transformers import AutoModelForImageTextToText, AutoProcessor


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', required=True)
    ap.add_argument('--adapter', help='adapter folder (default: <out_dir>/adapter)')
    opt = ap.parse_args()
    cfg = json.load(open(opt.config))
    adapter = opt.adapter or os.path.join(cfg['out_dir'], 'adapter')
    merged = cfg['merged_dir']
    if not os.path.exists(os.path.join(adapter, 'adapter_config.json')):
        sys.exit(f'no adapter at {adapter}: train first')
    status_path = os.path.join(cfg['out_dir'], 'train_status.json')
    if not opt.adapter and os.path.exists(status_path) and not json.load(open(status_path)).get('complete'):
        print('WARNING: training stopped early (time budget); merging the partial adapter')

    parent = os.path.dirname(merged.rstrip('/')) or '.'
    os.makedirs(parent, exist_ok=True)
    free_gb = shutil.disk_usage(parent).free / 1e9
    if free_gb < 11:
        sys.exit(f'only {free_gb:.1f} GB free under {parent}; the merged model needs ~10 GB. '
                 'Delete old checkpoints or point merged_dir at /tmp.')

    print('loading the base model in fp16 on the CPU…', flush=True)
    base = AutoModelForImageTextToText.from_pretrained(cfg['model_id'], dtype=torch.float16,
                                                       device_map='cpu', low_cpu_mem_usage=True)
    model = PeftModel.from_pretrained(base, adapter)
    model = model.merge_and_unload()
    model.config.use_cache = True
    if hasattr(model.config, 'text_config'):
        model.config.text_config.use_cache = True

    shutil.rmtree(merged, ignore_errors=True)
    model.save_pretrained(merged, max_shard_size='2GB')
    AutoProcessor.from_pretrained(cfg['model_id']).save_pretrained(merged)
    # Anything the processor did not write (generation config, video preprocessor, template).
    src = cfg['model_id']
    if not os.path.isdir(src):
        src = snapshot_download(src, allow_patterns=['*.json', '*.jinja', '*.txt'],
                                ignore_patterns=['model.safetensors.index.json'])
    for name in os.listdir(src):
        if os.path.isfile(os.path.join(src, name)) and not os.path.exists(os.path.join(merged, name)):
            shutil.copy2(os.path.join(src, name), os.path.join(merged, name))

    n = sum(p.numel() for p in model.parameters())
    has_visual = any('visual' in k for k in model.state_dict())
    print(f'merged model → {merged} ({n / 1e9:.2f}B params, vision tower kept: {has_visual})')
    print('files:', sorted(os.listdir(merged)))


if __name__ == '__main__':
    main()
