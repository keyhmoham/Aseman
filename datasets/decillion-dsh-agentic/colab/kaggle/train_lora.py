#!/usr/bin/env python3
"""QLoRA fine-tune of Qwen3.5-4B on the prepared Decillion dsh rows, one process per GPU (DDP).

    torchrun --standalone --nproc_per_node=2 train_lora.py --config /kaggle/working/run_config.json [--smoke]

Why this shape (2x T4, 15 GB each, 29 GB host RAM, 20 GB /kaggle/working, 12 h sessions):
  * Full fine-tuning does not fit: fp32 master weights + Adam + grads for ~4.6B params is >70 GB even with
    ZeRO-3 CPU offload. A 4-bit base with LoRA adapters fits in one T4 per process.
  * The rows are 7k-19k tokens but only ~3% of them are assistant tokens. Logits over the 248k vocabulary
    for every position would be 8-16 GB per row, so the loss is computed only at labelled positions, in
    chunks, with the lm_head recomputed in backward (peak <1 GB).
  * A time budget stops training with a saved checkpoint before Kaggle kills the session; the next session
    resumes from it (local, a Kaggle input dataset, or the Hugging Face Hub).
  * --smoke runs two training steps on the LONGEST rows to prove memory fits before a long run.
"""
import argparse, glob, json, math, os, sys, time

import torch
import torch.distributed as dist
import torch.nn.functional as F
from torch.utils.checkpoint import checkpoint

from datasets import load_from_disk
from peft import LoraConfig, get_peft_model
from transformers import (AutoModelForImageTextToText, AutoTokenizer, BitsAndBytesConfig, Trainer,
                          TrainerCallback, TrainingArguments)

# LoRA only on the language model: full-attention, Gated DeltaNet (linear attention) and MLP projections.
# The vision tower is never trained (this dataset is text-only) and stays in the checkpoint for vLLM.
LORA_TARGETS = (r'.*language_model\.layers\.\d+\.(self_attn\.(q_proj|k_proj|v_proj|o_proj)'
                r'|linear_attn\.(in_proj_qkv|in_proj_z|out_proj)|mlp\.(gate_proj|up_proj|down_proj))')
CE_CHUNK = 512  # labelled positions per lm_head chunk


# ---------------------------------------------------------------------------------------------------------------
# Attention that fits a T4 at 16k tokens.
# On Turing there is no FlashAttention, and for Qwen3.5's full-attention layers (head_dim 256, grouped-query
# attention) PyTorch's SDPA falls back to the "math" kernel, which materializes the whole [heads, L, L] score
# matrix in fp32: 16 x 16k x 16k x 4 B = 16 GB for a single layer. This implementation uses the memory-efficient
# kernel when a probe on this GPU shows it can run forward AND backward at this head size, and otherwise computes
# attention in query blocks, each recomputed in backward, so at most one block of scores (~1 GB at 16k) exists.
# ---------------------------------------------------------------------------------------------------------------
ATTN_IMPL = 't4_blocked'
ATTN_BLOCK = 1024
_EFFICIENT_OK = {}


def _repeat_kv(x, n):
    if n == 1:
        return x
    b, h, l, d = x.shape
    return x[:, :, None].expand(b, h, n, l, d).reshape(b, h * n, l, d)


def _efficient_kernel_works(device, dtype, head_dim):
    key = (str(device), dtype, head_dim)
    if key not in _EFFICIENT_OK:
        ok = False
        if device.type == 'cuda':
            try:
                import warnings
                from torch.nn.attention import SDPBackend, sdpa_kernel
                warnings.filterwarnings('ignore', message='.*kernel not used because.*')
                warnings.filterwarnings('ignore', message='.*has been runtime disabled.*')
                warnings.filterwarnings('ignore', message='.*Expected query, key and value.*')
                q, k, v = (torch.randn(1, 2, 256, head_dim, device=device, dtype=dtype, requires_grad=True)
                           for _ in range(3))
                with sdpa_kernel([SDPBackend.EFFICIENT_ATTENTION]):
                    F.scaled_dot_product_attention(q, k, v, is_causal=True).float().sum().backward()
                ok = all(torch.isfinite(t.grad).all() for t in (q, k, v))
            except Exception:
                ok = False
        _EFFICIENT_OK[key] = ok
        log(f'attention for head_dim {head_dim} on {device}: '
            + ('memory-efficient SDPA kernel' if ok else f'query-blocked attention ({ATTN_BLOCK} queries per block)'))
    return _EFFICIENT_OK[key]


def _attn_block(q, k, v, mask, q0, causal, scaling):
    """Scores for queries [q0, q0+bq) against keys [0, kend) only (causal), softmax in fp32."""
    bq = q.shape[2]
    kend = min(k.shape[2], q0 + bq) if causal else k.shape[2]
    k, v = k[:, :, :kend], v[:, :, :kend]
    scores = torch.matmul(q.float(), k.float().transpose(-1, -2)) * scaling
    if mask is not None:
        m = mask[..., q0:q0 + bq, :kend]
        scores = scores.masked_fill(~m, float('-inf')) if m.dtype == torch.bool else scores + m.float()
    if causal:
        qi = torch.arange(q0, q0 + bq, device=q.device)[:, None]
        kj = torch.arange(kend, device=q.device)[None, :]
        scores = scores.masked_fill(kj > qi, float('-inf'))
    probs = torch.softmax(scores, dim=-1).nan_to_num(0.0)  # fully masked rows (padding) -> 0
    return torch.matmul(probs.to(v.dtype), v)


def t4_attention_forward(module, query, key, value, attention_mask, dropout=0.0, scaling=None, is_causal=None,
                         **kwargs):
    n_rep = query.shape[1] // key.shape[1]
    key, value = _repeat_kv(key, n_rep), _repeat_kv(value, n_rep)
    scaling = scaling if scaling is not None else query.shape[-1] ** -0.5
    causal = (is_causal if is_causal is not None else getattr(module, 'is_causal', True)) and query.shape[2] > 1
    if attention_mask is not None and attention_mask.dim() == 4 and attention_mask.shape[-1] > key.shape[2]:
        attention_mask = attention_mask[..., :key.shape[2]]
    if _efficient_kernel_works(query.device, query.dtype, query.shape[-1]):
        from torch.nn.attention import SDPBackend, sdpa_kernel
        with sdpa_kernel([SDPBackend.EFFICIENT_ATTENTION]):
            out = F.scaled_dot_product_attention(query, key, value, attn_mask=attention_mask,
                                                 is_causal=causal and attention_mask is None, scale=scaling)
    else:
        # Causal masking is applied by position inside each block, so a 4D mask is only needed for padding.
        blocks = []
        for q0 in range(0, query.shape[2], ATTN_BLOCK):
            qb = query[:, :, q0:q0 + ATTN_BLOCK]
            if torch.is_grad_enabled():
                blocks.append(checkpoint(_attn_block, qb, key, value, attention_mask, q0, causal, scaling,
                                         use_reentrant=False))
            else:
                blocks.append(_attn_block(qb, key, value, attention_mask, q0, causal, scaling))
        out = torch.cat(blocks, dim=2)
    return out.transpose(1, 2).contiguous(), None


def register_t4_attention():
    from transformers import AttentionInterface
    from transformers.masking_utils import ALL_MASK_ATTENTION_FUNCTIONS, sdpa_mask
    AttentionInterface.register(ATTN_IMPL, t4_attention_forward)
    ALL_MASK_ATTENTION_FUNCTIONS.register(ATTN_IMPL, sdpa_mask)  # None when there is no padding


def rank0():
    return int(os.environ.get('RANK', '0')) == 0


def log(*a):
    if rank0():
        print(*a, flush=True)


class Collator:
    def __init__(self, pad_id):
        self.pad_id = pad_id

    def __call__(self, feats):
        n = max(len(f['input_ids']) for f in feats)
        ids = torch.full((len(feats), n), self.pad_id, dtype=torch.long)
        labels = torch.full((len(feats), n), -100, dtype=torch.long)
        mask = torch.zeros((len(feats), n), dtype=torch.long)
        for b, f in enumerate(feats):
            k = len(f['input_ids'])
            ids[b, :k] = torch.tensor(f['input_ids'])
            labels[b, :k] = torch.tensor(f['labels'])
            mask[b, :k] = 1
        return {'input_ids': ids, 'attention_mask': mask, 'labels': labels}


def _chunk_ce(h, weight, target):
    # Runs outside the Trainer's autocast (which wraps only the model's forward), so match dtypes explicitly.
    logits = F.linear(h.to(weight.dtype), weight).float()
    return F.cross_entropy(logits, target, reduction='sum')


def selected_ce(hidden, weight, target):
    """Summed cross entropy of hidden[n, d] @ weight.T against target[n], chunked and recomputed."""
    total = hidden.new_zeros((), dtype=torch.float32)
    for s in range(0, hidden.shape[0], CE_CHUNK):
        total = total + checkpoint(_chunk_ce, hidden[s:s + CE_CHUNK], weight, target[s:s + CE_CHUNK],
                                   use_reentrant=False)
    return total


class AssistantLossTrainer(Trainer):
    """Mean cross entropy over each row's assistant tokens; logits only where there is a label."""

    def compute_loss(self, model, inputs, return_outputs=False, num_items_in_batch=None):
        labels = inputs['labels']
        out = model(input_ids=inputs['input_ids'], attention_mask=inputs['attention_mask'],
                    use_cache=False, output_hidden_states=True, logits_to_keep=1)
        hidden = out.hidden_states[-1]                      # final-norm output, [B, L, d]
        target = labels[:, 1:]
        keep = target != -100
        h = hidden[:, :-1][keep]                            # positions whose NEXT token is a label
        t = target[keep]
        lm_head = self.accelerator.unwrap_model(model).get_output_embeddings()
        if t.numel() == 0:
            loss = hidden.sum() * 0.0
        else:
            loss = selected_ce(h, lm_head.weight, t) / t.numel()
        return (loss, {'loss': loss}) if return_outputs else loss


class TimeBudget(TrainerCallback):
    """Stop (with a checkpoint) before the session limit. All ranks decide together, or DDP would hang."""

    def __init__(self, seconds):
        self.deadline = time.time() + seconds
        self.hit = False

    def on_step_end(self, args, state, control, **kw):
        flag = torch.tensor([1.0 if time.time() > self.deadline else 0.0],
                            device='cuda' if torch.cuda.is_available() else 'cpu')
        if dist.is_available() and dist.is_initialized():
            dist.all_reduce(flag, op=dist.ReduceOp.MAX)
        if flag.item() > 0 and not self.hit:
            self.hit = True
            control.should_save = True
            control.should_training_stop = True
            log(f'time budget reached at step {state.global_step}: saving a checkpoint and stopping')
        return control


class NanGuard(TrainerCallback):
    """Logged losses are gathered across ranks, so every rank sees the same value and stops together."""

    def __init__(self, patience=3):
        self.bad, self.patience = 0, patience

    def on_log(self, args, state, control, logs=None, **kw):
        loss = (logs or {}).get('loss')
        if loss is None:
            return control
        self.bad = self.bad + 1 if not math.isfinite(loss) else 0
        if self.bad >= self.patience:
            log(f'loss is not finite for {self.bad} logs in a row: stopping. Lower the learning rate, or '
                'check the fp16 overflow notes in the notebook.')
            control.should_training_stop = True
        return control


def checkpointing_args():
    """Transformers renamed gradient_checkpointing to activation_checkpointing; accept either."""
    import dataclasses
    names = {f.name for f in dataclasses.fields(TrainingArguments)}
    key = 'activation_checkpointing' if 'activation_checkpointing' in names else 'gradient_checkpointing'
    return {key: True, f'{key}_kwargs': {'use_reentrant': False}}


def check_versions():
    import transformers, peft
    from transformers.models.auto.modeling_auto import MODEL_FOR_IMAGE_TEXT_TO_TEXT_MAPPING_NAMES as M
    log(f'torch {torch.__version__} | transformers {transformers.__version__} | peft {peft.__version__} | '
        f'GPUs {torch.cuda.device_count()}')
    if 'qwen3_5' not in M:
        raise RuntimeError(f'transformers {transformers.__version__} does not know Qwen3.5: cell 2 did not install '
                           'the pinned version. Rerun cell 2 and read its pip output (it is no longer quiet).')


def latest_checkpoint(*dirs):
    found = []
    for d in dirs:
        if d and os.path.isdir(d):
            found += [p for p in glob.glob(os.path.join(d, 'checkpoint-*'))
                      if os.path.exists(os.path.join(p, 'trainer_state.json'))]
            if os.path.exists(os.path.join(d, 'trainer_state.json')):
                found.append(d)  # a "last-checkpoint" folder from the Hub, or a checkpoint path itself
    if not found:
        return None
    return max(found, key=lambda p: json.load(open(os.path.join(p, 'trainer_state.json')))['global_step'])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', required=True)
    ap.add_argument('--smoke', action='store_true', help='2 steps on the longest rows, then stop')
    opt = ap.parse_args()
    cfg = json.load(open(opt.config))
    check_versions()
    register_t4_attention()
    cuda = torch.cuda.is_available()
    local_rank = int(os.environ.get('LOCAL_RANK', '0'))
    world = int(os.environ.get('WORLD_SIZE', '1'))
    if cuda:
        torch.cuda.set_device(local_rank)
    # torch.cuda.is_bf16_supported() also counts emulation and returns True on a T4: ask for real bf16 hardware.
    native_bf16 = cuda and torch.cuda.get_device_capability()[0] >= 8
    compute_dtype = torch.bfloat16 if native_bf16 else (torch.float16 if cuda else torch.float32)
    log(f'precision: {compute_dtype} ({"native bf16" if native_bf16 else "fp16 with loss scaling" if cuda else "cpu"})')

    out_dir = cfg['out_dir']
    ckpt_dir = os.path.join(out_dir, 'smoke' if opt.smoke else 'checkpoints')
    adapter_dir = os.path.join(out_dir, 'adapter')

    tok = AutoTokenizer.from_pretrained(cfg['model_id'])
    train_ds = load_from_disk(os.path.join(cfg['prepared_dir'], 'train'))
    eval_ds = load_from_disk(os.path.join(cfg['prepared_dir'], 'eval'))
    if opt.smoke:  # worst case for memory: the longest rows
        lens = [len(x) for x in train_ds['input_ids']]
        top = sorted(range(len(lens)), key=lambda i: -lens[i])[:2 * world]
        train_ds = train_ds.select(top)
        eval_ds = eval_ds.select(range(min(world, len(eval_ds))))
        log('smoke test on rows of', [lens[i] for i in top], 'tokens')

    steps_per_epoch = math.ceil(len(train_ds) / (world * cfg['grad_accum']))
    total_steps = 2 if opt.smoke else steps_per_epoch * cfg['epochs']
    eval_steps = max(1, cfg['eval_every'])
    args = TrainingArguments(
        output_dir=ckpt_dir,
        per_device_train_batch_size=1,          # rows are 7k-16k tokens; padding a batch would waste compute
        per_device_eval_batch_size=1,
        gradient_accumulation_steps=1 if opt.smoke else cfg['grad_accum'],
        num_train_epochs=cfg['epochs'],
        max_steps=total_steps,
        learning_rate=cfg['learning_rate'],
        lr_scheduler_type='cosine',
        warmup_steps=0 if opt.smoke else max(1, math.ceil(total_steps * cfg['warmup_ratio'])),
        weight_decay=0.0,
        optim='adamw_torch',
        max_grad_norm=1.0,
        fp16=cuda and not native_bf16,          # T4: fp16 (bf16 there is only emulated, and slow)
        bf16=native_bf16,
        **checkpointing_args(),
        logging_steps=1 if opt.smoke else 5,
        logging_first_step=True,
        eval_strategy='no' if opt.smoke else 'steps',
        eval_steps=eval_steps,
        save_strategy='no' if opt.smoke else 'steps',
        save_steps=cfg['save_every'],
        save_total_limit=2,
        prediction_loss_only=True,
        label_names=['labels'],
        remove_unused_columns=False,
        dataloader_num_workers=2,
        dataloader_pin_memory=cuda,
        ddp_find_unused_parameters=False,
        ddp_backend=None if cuda else 'gloo',  # gloo only for CPU dry runs
        report_to='none',
        seed=cfg['seed'],
        data_seed=cfg['seed'],
        push_to_hub=bool(cfg.get('hf_repo_id')) and not opt.smoke,
        hub_model_id=cfg.get('hf_repo_id') or None,
        hub_strategy='checkpoint',
        hub_private_repo=True,
    )

    quant = None
    if cuda and cfg['load_in_4bit']:
        quant = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type='nf4',
                                   bnb_4bit_use_double_quant=True, bnb_4bit_compute_dtype=compute_dtype,
                                   llm_int8_skip_modules=['visual', 'lm_head'])
    model = AutoModelForImageTextToText.from_pretrained(
        cfg['model_id'],
        dtype=compute_dtype,
        quantization_config=quant,
        device_map={'': local_rank} if cuda else None,
        attn_implementation=ATTN_IMPL,
    )
    model.config.use_cache = False
    if hasattr(model.config, 'text_config'):
        model.config.text_config.use_cache = False
    model.requires_grad_(False)
    model = get_peft_model(model, LoraConfig(
        r=cfg['lora_r'], lora_alpha=cfg['lora_alpha'], lora_dropout=cfg['lora_dropout'],
        target_modules=LORA_TARGETS, bias='none'))
    if rank0():
        model.print_trainable_parameters()

    trainer = AssistantLossTrainer(
        model=model, args=args, train_dataset=train_ds, eval_dataset=eval_ds,
        data_collator=Collator(tok.pad_token_id if tok.pad_token_id is not None else tok.eos_token_id),
        processing_class=tok,
        callbacks=[TimeBudget(cfg['time_budget_hours'] * 3600), NanGuard()],
    )
    # compute_loss already returns a per-row mean: let the Trainer divide by the accumulation steps.
    trainer.model_accepts_loss_kwargs = False
    if hasattr(trainer, 'loss_is_scaled_for_ga'):
        trainer.loss_is_scaled_for_ga = False

    resume = None if opt.smoke else latest_checkpoint(ckpt_dir, cfg.get('resume_from'))
    log(f'train rows {len(train_ds)} | eval rows {len(eval_ds)} | world {world} | '
        f'optimizer steps {total_steps} | resume from {resume}')
    t0 = time.time()
    trainer.train(resume_from_checkpoint=resume)
    took = time.time() - t0

    if opt.smoke:
        mem = torch.cuda.max_memory_allocated() / 2**30 if cuda else 0.0
        peak = torch.tensor([mem], device='cuda' if cuda else 'cpu')
        if dist.is_available() and dist.is_initialized():
            dist.all_reduce(peak, op=dist.ReduceOp.MAX)
        losses = [h['loss'] for h in trainer.state.log_history if 'loss' in h]
        ok = bool(losses) and all(math.isfinite(x) for x in losses)
        if rank0():
            sec_per_row = took / max(1, len(train_ds))
            rows_budget = int(cfg['time_budget_hours'] * 3600 / sec_per_row) if sec_per_row else 0
            res = {'ok': ok, 'losses': losses, 'peak_gib': round(peak.item(), 2),
                   'seconds': round(took, 1), 'sec_per_row_all_gpus': round(sec_per_row, 1),
                   'rows_that_fit_time_budget': rows_budget}
            json.dump(res, open(os.path.join(out_dir, 'smoke.json'), 'w'), indent=1)
            print('SMOKE', json.dumps(res), flush=True)
        if not ok:
            sys.exit(1)
        return

    complete = trainer.state.global_step >= total_steps
    metrics = trainer.evaluate()
    if 'eval_loss' in metrics:
        metrics['eval_perplexity'] = math.exp(min(float(metrics['eval_loss']), 20))
    trainer.save_model(adapter_dir)  # the LoRA adapter only (small); rank 0 writes
    if rank0():
        tok.save_pretrained(adapter_dir)
        status = {'complete': complete, 'global_step': trainer.state.global_step, 'max_steps': total_steps,
                  'hours_this_session': round(took / 3600, 2), 'eval': metrics,
                  'log_history': trainer.state.log_history[-50:]}
        json.dump(status, open(os.path.join(out_dir, 'train_status.json'), 'w'), indent=1)
        json.dump(metrics, open(os.path.join(out_dir, 'eval_metrics.json'), 'w'), indent=1)
        print('adapter →', adapter_dir, '| complete' if complete else
              f'| stopped at step {trainer.state.global_step}/{total_steps}: run the training cell again in '
              'a new session to resume', flush=True)
        print('eval:', metrics, flush=True)
    if cfg.get('hf_repo_id'):
        trainer.push_to_hub(commit_message='adapter' if complete else 'partial adapter')


if __name__ == '__main__':
    try:
        main()
    except BaseException:
        import traceback
        rank = os.environ.get('RANK', '0')
        msg = traceback.format_exc()
        try:
            cfg_path = sys.argv[sys.argv.index('--config') + 1]
            path = os.path.join(json.load(open(cfg_path))['out_dir'], f'error_rank{rank}.txt')
            open(path, 'w').write(msg)
        except Exception:
            pass
        print(f'[rank {rank}] FAILED\n{msg}', file=sys.stderr, flush=True)
        raise
