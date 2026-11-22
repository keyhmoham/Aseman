# Fine-tune Qwen3.5-4B for the Decillion dsh agentic system (Kaggle, 2×T4)

QLoRA on both T4s (one process per GPU, DDP). Run the cells in order, with **GPU T4 ×2** and **Internet on**.

**Why QLoRA, not full fine-tuning.** Full fine-tuning a ~4.6B-parameter model needs >70 GB for fp32 master weights,
Adam state and gradients, even with DeepSpeed ZeRO-3 CPU offload. Kaggle gives 29 GB of RAM, 2×15 GB of VRAM and 20 GB
of `/kaggle/working`. A 4-bit base with LoRA adapters fits on one T4 per process, and checkpoints are small.

**The data is long.** Rendered with Qwen3.5's own chat template, rows are 6.8k–18.7k tokens (median 13.4k), because the
dsh system prompt plus tool schemas is about 11k tokens. `MAX_SEQ_LEN = 16384` keeps about 99% of rows. Only about 3% of
tokens are the assistant's, so the loss (and the 248k-vocabulary logits) is computed only at those positions.

**What gets loss.** Only the assistant turns after the last real user message: from after `<|im_start|>assistant\n`
through `<|im_end|>`, including tool calls. Qwen3.5's template keeps `<think>` reasoning only for those turns. Earlier
turns stay in the context exactly as the model sees them in production, but they are not trained, because their format
(no `<think>` block) differs from what inference produces.

**Time.** A Kaggle session lasts at most 12 hours. Training stops itself with a checkpoint before `TIME_BUDGET_HOURS`.
Run the notebook again in a new session to resume, from this session's saved output (add it as an input) or from the
Hugging Face Hub (set `HF_REPO_ID` and a Kaggle secret `HF_TOKEN`). The smoke test (cell 7) measures the real speed on
the longest rows and tells you how many rows fit in the budget.

**Storage.** Only results go to `/kaggle/working` (adapter, checkpoints, merged model, metrics). The repository, the
built dataset, the vLLM environment and anything holding the API key stay under `/tmp/decillion`, which is not saved.

Cells: 1 hardware check · 2 install · 3 configuration · 4 build the dataset · 5 write the scripts · 6 choose and tokenize the mix ·
7 smoke test · 8 train · 9 metrics · 10 merge · 11 serve with vLLM · 12 Cloudflare tunnel ·
13 end-to-end API test.

Cells 2–10 are built from `colab/kaggle/` in the Aseman repository (`python3 colab/build_notebook.py`). Edit those files,
not this notebook.
