# 13. Serve the merged model with vLLM: an OpenAI-compatible API on port 8000
# After a runtime restart, run cells 1, 2 and 4 first; this cell finds the merged model on Drive.
import json, os, shutil, subprocess, sys, time, urllib.request
from importlib.metadata import PackageNotFoundError, version
import torch

OUT_DIR = globals().get('OUT_DIR', '/content/drive/MyDrive/decillion-qwen35-4b')
MODEL_ID = globals().get('MODEL_ID', 'Qwen/Qwen3.5-4B')
MERGED_DIR = globals().get('MERGED_DIR', f'{OUT_DIR}/merged')
SERVED_NAME = 'decillion-dsh-qwen35-4b'
PORT = 8000
MAX_LEN = max(int(globals().get('MAX_SEQ_LEN', 16384)), 16384)  # the context window to register in Decillion
VLLM_LOG = '/content/vllm.log'

assert os.path.exists(f'{MERGED_DIR}/config.json'), f'no merged model at {MERGED_DIR}: run cell 12 first'

# The merged folder can miss the processor/chat-template files of the multimodal base model.
from huggingface_hub import snapshot_download
base = snapshot_download(MODEL_ID, allow_patterns=[
    'preprocessor_config.json', 'video_preprocessor_config.json', 'processor_config.json',
    'chat_template.jinja', 'generation_config.json'])
for name in os.listdir(base):
    if os.path.isfile(f'{base}/{name}') and not os.path.exists(f'{MERGED_DIR}/{name}'):
        shutil.copy2(f'{base}/{name}', f'{MERGED_DIR}/{name}')

# Serve from local disk: mmap over the Drive FUSE mount is slow and unreliable.
LOCAL_DIR = '/content/merged'
stamp = f'{LOCAL_DIR}/.source-mtime'
src_mtime = os.path.getmtime(f'{MERGED_DIR}/config.json')
stale = (not os.path.exists(f'{LOCAL_DIR}/config.json') or not os.path.exists(stamp)
         or float(open(stamp).read()) < src_mtime)
if stale:
    print('copying the merged model to local disk (a few minutes)…')
    shutil.rmtree(LOCAL_DIR, ignore_errors=True)
    shutil.copytree(MERGED_DIR, LOCAL_DIR)
    open(stamp, 'w').write(str(src_mtime))

try:
    have_vllm = tuple(int(x) for x in version('vllm').split('.')[:2]) >= (0, 34)
except (PackageNotFoundError, ValueError):
    have_vllm = False
if not have_vllm:
    print('installing vLLM (a few minutes; it brings its own torch)…')
    !pip install -q -U 'vllm>=0.34.0'

# The tunnel publishes this port to the internet, so the API always needs a key.
API_KEY = globals().get('API_KEY') or 'sk-decillion-' + os.urandom(16).hex()
# T4 has no bf16; every other Colab GPU does.
DTYPE = 'bfloat16' if torch.cuda.is_bf16_supported() else 'float16'

subprocess.run(['pkill', '-f', 'vllm.entrypoints.openai.api_server'], capture_output=True)
time.sleep(3)
cmd = [
    sys.executable, '-m', 'vllm.entrypoints.openai.api_server',
    '--model', LOCAL_DIR,
    '--served-model-name', SERVED_NAME,
    '--host', '127.0.0.1', '--port', str(PORT),
    '--api-key', API_KEY,
    '--dtype', DTYPE,
    '--max-model-len', str(MAX_LEN),
    '--gpu-memory-utilization', '0.9' if DTYPE == 'float16' else '0.85',
    '--max-num-seqs', '8',
    # dsh's agentic calls: Qwen's XML <tool_call> blocks and its  thinking block
    '--enable-auto-tool-choice', '--tool-call-parser', 'qwen3_xml', '--reasoning-parser', 'qwen3',
    # this fine-tune is text-only: do not reserve memory for images or video
    '--limit-mm-per-prompt', '{"image": 0, "video": 0}',
]
if DTYPE == 'float16':
    cmd += ['--enforce-eager']   # a 16 GB T4: skip the CUDA graphs to keep 16k context in memory
print('starting vLLM…')
proc = subprocess.Popen(cmd, stdout=open(VLLM_LOG, 'w'), stderr=subprocess.STDOUT)

def served_ids():
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}/v1/models',
                                 headers={'Authorization': f'Bearer {API_KEY}'})
    return [m['id'] for m in json.load(urllib.request.urlopen(req, timeout=5))['data']]

deadline, ids = time.time() + 900, None
while time.time() < deadline and proc.poll() is None:
    try:
        ids = served_ids()
        break
    except Exception:
        time.sleep(5)
if ids != [SERVED_NAME]:
    print(open(VLLM_LOG).read()[-4000:])
    raise RuntimeError('vLLM did not come up: see its log above')

SERVE = {'base_url_local': f'http://127.0.0.1:{PORT}/v1', 'port': PORT, 'model': SERVED_NAME,
         'api_key': API_KEY, 'max_model_len': MAX_LEN, 'merged_dir': MERGED_DIR}
json.dump(SERVE, open(f'{OUT_DIR}/serve.json', 'w'), indent=1)
print('serving', SERVED_NAME, '→', SERVE['base_url_local'])
print('API key:', API_KEY, '| saved to', f'{OUT_DIR}/serve.json')
