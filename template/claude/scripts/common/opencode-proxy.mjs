#!/usr/bin/env node
// Local pass-through proxy for OpenCode Go / Zen.
// Copilot CLI's BYOK mode can't send custom headers, but OpenCode wants a client user agent and a
// stable x-opencode-session per conversation. This adds both and forwards everything else untouched
// (including streaming responses). Listens on 127.0.0.1 only.
//
// Env:
//   OPENCODE_UPSTREAM    default https://opencode.ai/zen/go   (use https://opencode.ai/zen for Zen)
//   OPENCODE_SESSION     default random per proxy start; with-opencode.sh sets one per run
//   OPENCODE_USER_AGENT  default copilot-governor/1.0
//   OPENCODE_PROXY_PORT  default 0 (pick a free port). The chosen port is printed on stdout.
// Each request is logged to stderr as: time METHOD path model=<id> -> status
import http from 'node:http';
import https from 'node:https';
import { randomUUID } from 'node:crypto';

const UPSTREAM = new URL(process.env.OPENCODE_UPSTREAM ?? 'https://opencode.ai/zen/go');
const SESSION = process.env.OPENCODE_SESSION ?? `copilot-${randomUUID()}`;
const USER_AGENT = process.env.OPENCODE_USER_AGENT ?? 'copilot-governor/1.0';
const PORT = Number(process.env.OPENCODE_PROXY_PORT ?? 0);
const HOST = '127.0.0.1';
const client = UPSTREAM.protocol === 'http:' ? http : https;
const HOP_BY_HOP = ['connection', 'keep-alive', 'proxy-connection', 'upgrade'];

const server = http.createServer((req, res) => {
  const target = new URL(UPSTREAM.pathname.replace(/\/$/, '') + req.url, UPSTREAM.origin);
  const headers = { ...req.headers, host: target.host, 'x-opencode-session': SESSION, 'user-agent': USER_AGENT };
  for (const h of HOP_BY_HOP) delete headers[h];

  // Tap the request body (while still streaming it) so each call is logged with its model.
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  const modelOf = () => {
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')).model ?? '-'; } catch { return '-'; }
  };

  const upstream = client.request(target, { method: req.method, headers }, (up) => {
    console.error(`${new Date().toISOString()} ${req.method} ${target.pathname} model=${modelOf()} -> ${up.statusCode}`);
    res.writeHead(up.statusCode ?? 502, up.headers);
    up.pipe(res);
  });
  upstream.on('error', (err) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { type: 'proxy_error', message: err.message } }));
  });
  req.pipe(upstream);
});

server.listen(PORT, HOST, () => {
  const { port } = server.address();
  process.stdout.write(`${port}\n`);
  console.error(`opencode-proxy http://${HOST}:${port} -> ${UPSTREAM.href} (session ${SESSION})`);
});

for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => server.close(() => process.exit(0)));
