// Outbound HTTP for backend programs: `askHost('aseman.fetch', {url, ...})`.
//
// A backend runs on the node's own network (managed) or inside a space's
// sandbox (installed), so its requests are held to the public internet:
// only http(s), every address the host name resolves to must be public, and
// the connection is pinned to the address that was checked (a name that
// resolves differently on the second lookup cannot reach the node's
// neighbours). Bounded in time and size.

import dns from 'node:dns/promises';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';

const blocked = new net.BlockList();
for (const [prefix, bits, type] of [
  ['0.0.0.0', 8, 'ipv4'], ['10.0.0.0', 8, 'ipv4'], ['100.64.0.0', 10, 'ipv4'],
  ['127.0.0.0', 8, 'ipv4'], ['169.254.0.0', 16, 'ipv4'], ['172.16.0.0', 12, 'ipv4'],
  ['192.0.0.0', 24, 'ipv4'], ['192.168.0.0', 16, 'ipv4'], ['198.18.0.0', 15, 'ipv4'],
  ['224.0.0.0', 4, 'ipv4'], ['240.0.0.0', 4, 'ipv4'],
  ['::', 128, 'ipv6'], ['::1', 128, 'ipv6'], ['fc00::', 7, 'ipv6'], ['fe80::', 10, 'ipv6'],
  ['ff00::', 8, 'ipv6'],
]) {
  blocked.addSubnet(prefix, bits, type);
}

/** Whether an address is outside the public internet. */
export function isPrivateAddress(address) {
  const family = net.isIP(address);
  if (family === 0) return true;
  // An IPv4-mapped IPv6 address is judged by its IPv4 address. (Not by a
  // ::ffff:0:0/96 subnet in the list: BlockList matches every IPv4 address
  // against that subnet, which would refuse the whole internet.)
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(address);
  if (mapped) return isPrivateAddress(mapped[1]);
  return blocked.check(address, family === 4 ? 'ipv4' : 'ipv6');
}

/**
 * A fetcher for backend programs. Returns {status, ok, contentType, text,
 * json} (json when the body is JSON).
 */
export function createFetcher({
  allowPrivate = process.env.ASEMAN_TOOL_FETCH_ALLOW_PRIVATE === 'true',
  timeoutMs = 10_000,
  maxBytes = 2 << 20,
  lookup = (host) => dns.lookup(host, { all: true }),
} = {}) {
  return async (request) => {
    const input = typeof request === 'string' ? { url: request } : request ?? {};
    let url;
    try {
      url = new URL(String(input.url ?? ''));
    } catch {
      throw new Error('fetch needs an absolute http(s) URL');
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('fetch reaches http(s) URLs only');
    if (url.username || url.password) throw new Error('fetch URLs carry no credentials');
    const method = String(input.method ?? 'GET').toUpperCase();
    if (!['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'].includes(method)) throw new Error(`unsupported method ${method}`);

    const host = url.hostname.replace(/^\[|\]$/g, '');
    const addresses = net.isIP(host) ? [{ address: host, family: net.isIP(host) }] : await lookup(host);
    if (!addresses.length) throw new Error(`cannot resolve ${host}`);
    if (!allowPrivate && addresses.some((a) => isPrivateAddress(a.address))) {
      throw new Error(`${host} is not on the public internet`);
    }
    const pinned = addresses[0];

    const body = input.body === undefined || input.body === null
      ? undefined
      : typeof input.body === 'string' ? input.body : JSON.stringify(input.body);
    const headers = { 'user-agent': 'aseman-tool-runtime/1', accept: 'application/json, text/*;q=0.9, */*;q=0.5' };
    for (const [k, v] of Object.entries(input.headers ?? {})) headers[String(k).toLowerCase()] = String(v);
    if (body !== undefined && !headers['content-type']) headers['content-type'] = 'application/json';

    const client = url.protocol === 'https:' ? https : http;
    return new Promise((resolve, reject) => {
      let settled = false;
      const fail = (error) => {
        if (settled) return;
        settled = true;
        req.destroy();
        reject(error);
      };
      const req = client.request(url, {
        method,
        headers,
        timeout: timeoutMs,
        // Connect to the address that was checked, whatever DNS says now.
        lookup: (_host, options, callback) => {
          if (options && options.all) callback(null, [{ address: pinned.address, family: pinned.family }]);
          else callback(null, pinned.address, pinned.family);
        },
      }, (res) => {
        const chunks = [];
        let size = 0;
        res.on('data', (chunk) => {
          size += chunk.length;
          if (size > maxBytes) {
            fail(new Error(`response larger than ${maxBytes} bytes`));
            return;
          }
          chunks.push(chunk);
        });
        res.on('error', fail);
        res.on('end', () => {
          if (settled) return;
          settled = true;
          const text = Buffer.concat(chunks).toString('utf8');
          let json;
          try {
            json = JSON.parse(text);
          } catch {
            json = undefined;
          }
          resolve({
            status: res.statusCode ?? 0,
            ok: (res.statusCode ?? 0) >= 200 && (res.statusCode ?? 0) < 300,
            contentType: String(res.headers['content-type'] ?? ''),
            text: json === undefined ? text : '',
            json: json ?? null,
          });
        });
      });
      req.on('timeout', () => fail(new Error(`timed out after ${timeoutMs} ms`)));
      req.on('error', fail);
      if (body !== undefined) req.write(body);
      req.end();
    });
  };
}
