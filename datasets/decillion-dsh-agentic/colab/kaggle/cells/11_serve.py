# 11. Serve the merged model with vLLM: an OpenAI-compatible API on port 8000, across both T4s.
# vLLM goes into its own virtual environment under /tmp: it brings its own torch, which would otherwise replace
# the one the training cells use.
import json, os, subprocess, sys, time, urllib.request

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
!{VENV}/bin/python -c "import vllm, torch; print('vllm', vllm.__version__, '| torch', torch.__version__)"

# The tunnel publishes this port to the internet, so the API always needs a key. Set a Kaggle secret
# DECILLION_API_KEY to keep it stable across sessions; otherwise a new one is generated.
API_KEY = None
try:
    from kaggle_secrets import UserSecretsClient
    API_KEY = UserSecretsClient().get_secret('DECILLION_API_KEY')
except Exception:
    pass
API_KEY = API_KEY or globals().get('API_KEY') or 'sk-decillion-' + os.urandom(16).hex()

subprocess.run(['pkill', '-f', 'vllm.entrypoints.openai.api_server'], capture_output=True)
time.sleep(3)
cmd = [f'{VENV}/bin/python', '-m', 'vllm.entrypoints.openai.api_server',
       '--model', MERGED_DIR, '--served-model-name', SERVED_NAME,
       '--host', '127.0.0.1', '--port', str(PORT), '--api-key', API_KEY,
       '--dtype', 'float16',                   # T4 has no bf16
       '--max-model-len', str(MAX_LEN), '--tensor-parallel-size', '2',
       '--gpu-memory-utilization', '0.90', '--max-num-seqs', '4',
       '--enforce-eager',                      # no CUDA graphs: less memory pressure on T4
       '--enable-auto-tool-choice', '--tool-call-parser', TOOL_PARSER, '--reasoning-parser', 'qwen3',
       '--limit-mm-per-prompt', '{"image": 0, "video": 0}']   # text-only fine-tune: no vision memory
print('starting vLLM…')
proc = subprocess.Popen(cmd, stdout=open(VLLM_LOG, 'w'), stderr=subprocess.STDOUT)

def served_ids():
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}/v1/models', headers={'Authorization': f'Bearer {API_KEY}'})
    return [m['id'] for m in json.load(urllib.request.urlopen(req, timeout=5))['data']]

deadline, ids = time.time() + 1200, None
while time.time() < deadline and proc.poll() is None:
    try:
        ids = served_ids()
        break
    except Exception:
        time.sleep(5)
if ids != [SERVED_NAME]:
    print(open(VLLM_LOG).read()[-5000:])
    raise RuntimeError('vLLM did not come up: see its log above (on T4, check for unsupported-GPU errors from '
                       'the attention or linear-attention kernels; lowering MAX_LEN helps with out-of-memory)')

SERVE = {'base_url_local': f'http://127.0.0.1:{PORT}/v1', 'port': PORT, 'model': SERVED_NAME,
         'api_key': API_KEY, 'max_model_len': MAX_LEN, 'merged_dir': MERGED_DIR}
SERVE_JSON = f'{SECRETS}/serve.json'      # holds the key: kept out of /kaggle/working, which is saved and shareable
json.dump(SERVE, open(SERVE_JSON, 'w'), indent=1)
print('serving', SERVED_NAME, '→', SERVE['base_url_local'], '| API key saved to', SERVE_JSON)
