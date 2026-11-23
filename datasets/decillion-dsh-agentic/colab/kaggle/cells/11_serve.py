# 11. Serve the merged model with vLLM: an OpenAI-compatible API on port 8000 (both T4s, or one if that fails).
# vLLM goes into its own virtual environment under /tmp: it brings its own torch, which would otherwise replace
# the one the training cells use.
import json, math, os, re, subprocess, sys, time, urllib.request

SERVED_NAME = 'decillion-dsh-qwen35-4b'
PORT = 8000
MAX_LEN = 400_000        # context window served. Qwen3.5-4B is native to 262,144 tokens; above that, YaRN rotary
                         # scaling is switched on below (set MAX_LEN = 20480 to serve without it).
NATIVE_LEN = 262_144
SHORT_LEN = 20_480       # what a single T4 can hold, if both T4s fail (dsh prompts are 6.8k-18.7k tokens)
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

# On CUDA, vLLM 0.34 always uses its NVIDIA-optimized Qwen3.5 code (vllm/models/qwen3_5/nvidia), which calls
# FlashInfer RMSNorm kernels that do not build for Turing (the T4 fails a JIT "norm" compile). vLLM still ships the
# previous generic implementation (used on ROCm and other platforms). This tiny vLLM plugin, loaded by every vLLM
# process, registers the generic one for Qwen3.5 on GPUs older than compute capability 8.0.
PLUGIN = f'{TMP}/vllm_t4_plugin'
os.makedirs(f'{PLUGIN}/vllm_t4_plugin', exist_ok=True)
open(f'{PLUGIN}/pyproject.toml', 'w').write(
    '[project]\nname = "vllm-t4-plugin"\nversion = "0.1.0"\n'
    '[project.entry-points."vllm.general_plugins"]\nt4_qwen35 = "vllm_t4_plugin:register"\n'
    '[build-system]\nrequires = ["setuptools"]\nbuild-backend = "setuptools.build_meta"\n')
open(f'{PLUGIN}/vllm_t4_plugin/__init__.py', 'w').write('''
# Use vLLM's generic Qwen3.5 implementation on pre-Ampere GPUs (its NVIDIA one needs FlashInfer kernels).
GENERIC = "vllm.model_executor.models.qwen3_5"
ARCHS = ["Qwen3_5ForConditionalGeneration", "Qwen3_5ForCausalLM",
         "Qwen3_5MoeForConditionalGeneration", "Qwen3_5MoeForCausalLM"]


def register():
    from vllm import ModelRegistry
    from vllm.logger import init_logger
    from vllm.platforms import current_platform
    if not current_platform.is_cuda():
        return
    cap = current_platform.get_device_capability()   # NVML: does not initialize CUDA in this process
    if cap is None or cap.major >= 8:
        return
    for arch in ARCHS:
        ModelRegistry.register_model(arch, GENERIC + ":" + arch)
    init_logger(__name__).info("compute capability %s.%s: using the generic Qwen3.5 implementation",
                               cap.major, cap.minor)
''')
!uv pip install -q --python {VENV}/bin/python --reinstall {PLUGIN}
!env -u PYTHONPATH PYTHONNOUSERSITE=1 {VENV}/bin/python -c "from vllm.plugins import load_general_plugins; load_general_plugins(); from vllm import ModelRegistry; m = ModelRegistry.models['Qwen3_5ForConditionalGeneration']; print('Qwen3.5 implementation:', getattr(m, 'module_name', m))"
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
env.update(PYTHONNOUSERSITE='1', VLLM_WORKER_MULTIPROC_METHOD='spawn', TOKENIZERS_PARALLELISM='false',
           VLLM_USE_FLASHINFER_SAMPLER='0')   # FlashInfer's sampler is JIT-compiled too: use vLLM's own on T4

# KV cache: only the 8 full-attention layers keep one: 8 layers x (K, V) x 4 KV heads x 256 dims x 2 bytes = 32 KiB
# per token, 400k tokens = 12.2 GiB, split over 2 T4s (6.1 GiB each) next to ~4.7 GB of weights each. It fits on
# 2xT4 only (one T4 cannot also hold the 9.3 GB model), with room for about one full-length request at a time.
def kv_gib(tokens, tp):
    return tokens * 8 * 2 * (4 / tp) * 256 * 2 / 2**30

def rope_overrides(max_len):
    """YaRN for contexts beyond the native 262,144 tokens, in the Transformers convention vLLM follows:
    max_position_embeddings is the extended length, original_max_position_embeddings the native one."""
    if max_len <= NATIVE_LEN:
        return None
    text = json.load(open(f'{MERGED_DIR}/config.json')).get('text_config', {})
    rope = dict(text.get('rope_parameters') or {})
    factor = math.ceil(max_len / NATIVE_LEN * 100) / 100          # 400k -> 1.53: the smallest stretch that fits
    rope.update(rope_type='yarn', factor=factor, original_max_position_embeddings=NATIVE_LEN)
    return {'text_config': {'rope_parameters': rope, 'max_position_embeddings': math.ceil(NATIVE_LEN * factor)}}

def vllm_cmd(tp, max_len):
    over = rope_overrides(max_len)
    extra = ['--hf-overrides', json.dumps(over)] if over else []
    return [f'{VENV}/bin/python', '-m', 'vllm.entrypoints.openai.api_server',
            '--model', MERGED_DIR, '--served-model-name', SERVED_NAME,
            '--host', '127.0.0.1', '--port', str(PORT), '--api-key', API_KEY,
            '--dtype', 'float16',                     # T4 has no bf16
            '--max-model-len', str(max_len), '--tensor-parallel-size', str(tp),
            '--gpu-memory-utilization', '0.92', '--max-num-seqs', '2' if max_len > 65536 else '4',
            '--max-num-batched-tokens', '4096',       # prefill in 4k-token chunks: bounded activation memory
            '--enforce-eager',                        # no CUDA graphs: less memory pressure on T4
            '--language-model-only',                  # text-only fine-tune: skip the vision tower entirely
            '--attention-backend', 'TRITON_ATTN',     # the backend that supports Turing at head size 256
            '--gdn-prefill-backend', 'triton',        # linear-attention layers: Triton/FLA kernels
            '--disable-custom-all-reduce',            # Kaggle's T4s have no peer-to-peer link
            '--enable-auto-tool-choice', '--tool-call-parser', TOOL_PARSER, '--reasoning-parser', 'qwen3'] + extra

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

attempts = [(2, MAX_LEN)]
if MAX_LEN <= SHORT_LEN:
    attempts.append((1, MAX_LEN))
else:
    attempts.append((1, SHORT_LEN))  # last resort: one T4 cannot hold a long context next to the 9.3 GB model
proc = None
for tp, max_len in attempts:
    subprocess.run(['pkill', '-f', 'vllm.entrypoints.openai.api_server'], capture_output=True)
    time.sleep(5)
    over = rope_overrides(max_len)
    print(f'starting vLLM on {tp} GPU(s), context {max_len:,} tokens'
          + (f' (YaRN factor {over["text_config"]["rope_parameters"]["factor"]})' if over else '')
          + f', KV cache ~{kv_gib(max_len, tp):.1f} GiB per GPU… (log: {VLLM_LOG})', flush=True)
    if tp == 1 and max_len < MAX_LEN:
        print(f'NOTE: falling back to {max_len:,} tokens on one T4: {MAX_LEN:,} only fits across both')
    proc = subprocess.Popen(vllm_cmd(tp, max_len), stdout=open(VLLM_LOG, 'w'), stderr=subprocess.STDOUT, env=env)
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
TP, MAX_LEN = tp, max_len

SERVE = {'base_url_local': f'http://127.0.0.1:{PORT}/v1', 'port': PORT, 'model': SERVED_NAME,
         'api_key': API_KEY, 'max_model_len': MAX_LEN, 'merged_dir': MERGED_DIR, 'tensor_parallel': TP}
SERVE_JSON = f'{SECRETS}/serve.json'      # holds the key: kept out of /kaggle/working, which is saved and shareable
json.dump(SERVE, open(SERVE_JSON, 'w'), indent=1)
print('serving', SERVED_NAME, '→', SERVE['base_url_local'], '| API key saved to', SERVE_JSON)
