import assert from 'node:assert/strict';
import http from 'node:http';
import test from 'node:test';
import { hostApis } from '../lib/contract.mjs';
import { createFetcher, isPrivateAddress } from '../lib/fetch.mjs';

test('private, loopback, link-local and metadata addresses are not public', () => {
  for (const a of ['127.0.0.1', '10.1.2.3', '172.20.0.5', '192.168.1.1', '169.254.169.254', '100.64.0.1', '0.0.0.0', '::1', 'fd00::1', 'fe80::1', '::ffff:127.0.0.1']) {
    assert.equal(isPrivateAddress(a), true, a);
  }
  for (const a of ['1.1.1.1', '8.8.8.8', '2606:4700:4700::1111']) assert.equal(isPrivateAddress(a), false, a);
});

test('a host that resolves to a private address is refused before connecting', async () => {
  const fetch = createFetcher({ lookup: async () => [{ address: '10.0.0.7', family: 4 }] });
  await assert.rejects(fetch({ url: 'http://internal.example/' }), /not on the public internet/);
  await assert.rejects(createFetcher()({ url: 'http://127.0.0.1:1/' }), /not on the public internet/);
  await assert.rejects(createFetcher()({ url: 'file:///etc/passwd' }), /http\(s\) URLs only/);
  await assert.rejects(createFetcher()({ url: 'http://user:pw@example.com/' }), /no credentials/);
});

test('fetches JSON, pinned to the checked address, within its size bound', async () => {
  const server = http.createServer((req, res) => {
    if (req.url === '/big') {
      res.end('x'.repeat(5000));
      return;
    }
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ path: req.url, host: req.headers.host }));
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  // The name "public.example" resolves (here) to the test server.
  const fetch = createFetcher({ allowPrivate: true, maxBytes: 1000, lookup: async () => [{ address: '127.0.0.1', family: 4 }] });
  try {
    const res = await fetch({ url: `http://public.example:${port}/v1/forecast?x=1` });
    assert.equal(res.ok, true);
    assert.deepEqual(res.json, { path: '/v1/forecast?x=1', host: `public.example:${port}` });
    await assert.rejects(fetch({ url: `http://public.example:${port}/big` }), /larger than 1000 bytes/);
  } finally {
    server.close();
  }
});

test('a program gets no network unless the runtime gives it one', async () => {
  await assert.rejects(hostApis({}, null)('tradera.fetch', { url: 'https://example.com' }), /no network/);
  const calls = [];
  const out = await hostApis({}, null, () => {}, async (r) => { calls.push(r); return { ok: true }; })('tradera.fetch', { url: 'https://example.com' });
  assert.deepEqual(out, { ok: true });
  assert.equal(calls[0].url, 'https://example.com');
});
