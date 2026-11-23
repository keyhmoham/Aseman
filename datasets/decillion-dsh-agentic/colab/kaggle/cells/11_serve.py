# 11. Serve the merged model with vLLM: an OpenAI-compatible API on port 8000 (both T4s, or one if that fails).
# vLLM goes into its own virtual environment under /tmp: it brings its own torch, which would otherwise replace
# the one the training cells use.
import json, os, re, subprocess, sys, time, urllib.request

SERVED_NAME = 'decillion-dsh-qwen35-4b'
PORT = 8000
MAX_LEN = 20480          # dsh prompts are 6.8k-18.7k tokens, plus room for the reply. Only 8 of the 32 layers keep a
                         # KV cache (the rest are linear attention), so this fits on 2xT4 with tensor parallelism.
VLLM_SPEC = 'vllm==0.34.0'
TOOL_PARSER = 'qwen3_coder'   # Qwen3.5 writes <tool_call><function=…><parameter=…> blocks (the Qwen3-Coder format)
VENV = f'{TMP}/vllm-env'
SECRETS = f'{TMP}/secrets'
VLLM_LOG = f'{TMP}/vllm.log'
os.makedirs(SECRETS, exist_ok=True)
assert os.path.exists(f'{MERGED_DIR}/config.json'), f'no merged model at {MERGED_DIR}: run cell 10 first'
if os.path.exists(f'{MERGED_DIR}/merged_from.json'):
    print('serving the model merged from', json.load(open(f'{MERGED_DIR}/merged_from.json'))['adapter'])

if not os.path.exists(f'{VENV}/bin/vllm'):
    print('installing vLLM into', VENV, '(a few minutes)…')
    !pip install -q uv
    !uv venv -q --python {sys.executable} {VENV}
    !uv pip install -q --python {VENV}/bin/python {VLLM_SPEC}
# wrapt: Kaggle's sitecustomize hook imports it in every Python process, this environment's included.
!uv pip install -q --python {VENV}/bin/python wrapt
!env -u PYTHONPATH PYTHONNOUSERSITE=1 {VENV}/bin/python -c "import vllm, torch; print('vllm', vllm.__version__, '| torch', torch.__version__, '| GPUs', torch.cuda.device_count())"

# The tunnel publishes this port to the internet, so the API always needs a key. Set a Kaggle secret
# DECILLION_API_KEY to keep it stable across sessions; otherwise a new one is generated.
API_KEY = None
try:
    from kaggle_secrets import UserSecretsClient
    API_KEY = UserSecretsClient().get_secret('DECILLION_API_KEY')
except Exception:
    pass
API_KEY = API_KEY or globals().get('API_KEY') or 'sk-decillion-' + os.urandom(16).hex()

# vLLM runs in its own environment: start it with a clean one. Kaggle's PYTHONPATH and sitecustomize hooks would
# otherwise load into it ("Error in sitecustomize … No module named 'wrapt'") and can break its worker processes.
env = {k: v for k, v in os.environ.items() if k not in ('PYTHONPATH', 'PYTHONSTARTUP', 'PYTHONHOME')}
env.update(PYTHONNOUSERSITE='1', VLLM_WORKER_MULTIPROC_METHOD='spawn', TOKENIZERS_PARALLELISM='false')

def vllm_cmd(tp):
    return [f'{VENV}/bin/python', '-m', 'vllm.entrypoints.openai.api_server',
            '--model', MERGED_DIR, '--served-model-name', SERVED_NAME,
            '--host', '127.0.0.1', '--port', str(PORT), '--api-key', API_KEY,
            '--dtype', 'float16',                     # T4 has no bf16
            '--max-model-len', str(MAX_LEN), '--tensor-parallel-size', str(tp),
            '--gpu-memory-utilization', '0.90' if tp > 1 else '0.92', '--max-num-seqs', '4',
            '--max-num-batched-tokens', '4096',       # prefill in 4k-token chunks: bounded activation memory
            '--enforce-eager',                        # no CUDA graphs: less memory pressure on T4
            '--language-model-only',                  # text-only fine-tune: skip the vision tower entirely
            '--attention-backend', 'TRITON_ATTN',     # the backend that supports Turing at head size 256
            '--gdn-prefill-backend', 'triton',        # linear-attention layers: Triton/FLA kernels
            '--disable-custom-all-reduce',            # Kaggle's T4s have no peer-to-peer link
            '--enable-auto-tool-choice', '--tool-call-parser', TOOL_PARSER, '--reasoning-parser', 'qwen3']

def served_ids():
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}/v1/models', headers={'Authorization': f'Bearer {API_KEY}'})
    return [m['id'] for m in json.load(urllib.request.urlopen(req, timeout=5))['data']]

def root_cause(log_text):
    """The first real error from vLLM's engine/worker processes, not the generic wrapper error at the end."""
    lines = log_text.splitlines()
    wrapper = ('Engine core initialization failed', 'Failed core proc', 'wait_for_engine_startup',
               'build_async_engine_client', 'run_server')
    out = []
    starts = [i for i, l in enumerate(lines) if 'Traceback (most recent call last)' in l]
    for n, i in enumerate(starts):
        stop = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = '\n'.join(lines[i:min(stop, i + 70)])
        if not any(w in block for w in wrapper):
            out.append(block)
            break
    errors = [l for l in lines if re.search(r'\bERROR\b|\w+Error\b|CUDA error|out of memory|OutOfResources', l)
              and not any(w in l for w in wrapper)]
    if errors:
        out.append('error lines:\n' + '\n'.join(list(dict.fromkeys(errors))[:40]))
    return '\n\n'.join(out) or '\n'.join(lines[-80:])

attempts = [2, 1]   # both T4s first; one T4 also fits this model (9.3 GB fp16, KV cache only in 8 layers)
proc = None
for tp in attempts:
    subprocess.run(['pkill', '-f', 'vllm.entrypoints.openai.api_server'], capture_output=True)
    time.sleep(5)
    print(f'starting vLLM on {tp} GPU(s)… (log: {VLLM_LOG})', flush=True)
    proc = subprocess.Popen(vllm_cmd(tp), stdout=open(VLLM_LOG, 'w'), stderr=subprocess.STDOUT, env=env)
    deadline, ids = time.time() + 1200, None
    while time.time() < deadline and proc.poll() is None:
        try:
            ids = served_ids()
            break
        except Exception:
            time.sleep(5)
    if ids == [SERVED_NAME]:
        break
    proc.kill()
    log_text = open(VLLM_LOG).read()
    open(f'{OUT_DIR}/logs/vllm_tp{tp}.log', 'w').write(log_text.replace(API_KEY, '<API_KEY>'))
    print('=' * 30, f'vLLM failed on {tp} GPU(s): root cause', '=' * 30)
    print(root_cause(log_text).replace(API_KEY, '<API_KEY>'))
    print(f'(full log without the key: {OUT_DIR}/logs/vllm_tp{tp}.log)\n')
else:
    raise RuntimeError('vLLM did not come up in any configuration: send the root-cause sections above')
TP = tp

SERVE = {'base_url_local': f'http://127.0.0.1:{PORT}/v1', 'port': PORT, 'model': SERVED_NAME,
         'api_key': API_KEY, 'max_model_len': MAX_LEN, 'merged_dir': MERGED_DIR, 'tensor_parallel': TP}
SERVE_JSON = f'{SECRETS}/serve.json'      # holds the key: kept out of /kaggle/working, which is saved and shareable
json.dump(SERVE, open(SERVE_JSON, 'w'), indent=1)
print('serving', SERVED_NAME, '→', SERVE['base_url_local'], '| API key saved to', SERVE_JSON)
