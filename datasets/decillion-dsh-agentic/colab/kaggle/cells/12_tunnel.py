# 12. Expose the vLLM API to the internet with a Cloudflare quick tunnel (no account needed)
import json, os, re, subprocess, time, urllib.request

SERVE_JSON = f'{TMP}/secrets/serve.json'
SERVE = json.load(open(SERVE_JSON))
PORT, API_KEY = SERVE['port'], SERVE['api_key']
CF, CF_LOG = f'{TMP}/bin/cloudflared', f'{TMP}/cloudflared.log'
os.makedirs(os.path.dirname(CF), exist_ok=True)
if not os.path.exists(CF):
    !wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O {CF}
    !chmod +x {CF}

# Make sure the model is still up before publishing it.
req = urllib.request.Request(f'http://127.0.0.1:{PORT}/v1/models', headers={'Authorization': f'Bearer {API_KEY}'})
urllib.request.urlopen(req, timeout=10).read()

subprocess.run(['pkill', '-f', 'cloudflared tunnel'], capture_output=True)
time.sleep(2)
if os.path.exists(CF_LOG):
    os.remove(CF_LOG)
# HTTP/2 uses TCP 443 and is often more reliable in hosted notebook environments.
subprocess.Popen([CF, 'tunnel', '--url', f'http://127.0.0.1:{PORT}', '--no-autoupdate', '--protocol', 'http2',
                  '--logfile', CF_LOG], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

url, deadline = None, time.time() + 90
while time.time() < deadline and not url:
    time.sleep(2)
    if os.path.exists(CF_LOG):
        m = re.search(r'https://[a-z0-9-]+\.trycloudflare\.com', open(CF_LOG).read())
        url = m.group(0) if m else None
if not url:
    print(open(CF_LOG).read()[-2000:] if os.path.exists(CF_LOG) else '')
    raise RuntimeError('cloudflared printed no URL')
print('public URL:', url)

def public_ids():
    req = urllib.request.Request(f'{url}/v1/models', headers={'Authorization': f'Bearer {API_KEY}'})
    return [m['id'] for m in json.load(urllib.request.urlopen(req, timeout=10))['data']]

deadline = time.time() + 120
while True:
    try:
        ids = public_ids()
        break
    except Exception as exc:
        if time.time() > deadline:
            raise RuntimeError(f'the tunnel is up but the API is not reachable yet: {exc}')
        time.sleep(3)

SERVE['base_url_public'] = url + '/v1'
json.dump(SERVE, open(SERVE_JSON, 'w'), indent=1)
print('reachable from the internet →', SERVE['base_url_public'], '| model', ids[0])
print('This URL lives only while this session and cloudflared stay up; rerun this cell and update the provider in')
print('Decillion if it changes. A named Cloudflare tunnel (dashboard → token) gives a stable hostname instead.')
