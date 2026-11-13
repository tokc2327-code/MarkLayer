// 原生缩放验收集:起 fixture 服务 + 起 Chrome(可被真人按键),持续采样 DPR/缩放/元素矩形。
// 用法(node native-zoom.mjs):跑起来后由外部真人按 Ctrl+= / Ctrl+- / Ctrl+0;写一个 stop 文件即停。

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { appendFile, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = here;
const shotsDir = path.join(here, 'shots');
if (!existsSync(shotsDir)) mkdirSync(shotsDir, { recursive: true });
const readingsPath = path.join(here, 'readings.jsonl');
const stopPath = path.join(here, 'stop');
const PORT = 8792;
const CDP_PORT = 19456;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 1) 静态服务
const html = readFileSync(path.join(here, 'fixture.html'), 'utf8');
const server = createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(html);
});
await new Promise((r) => server.listen(PORT, '127.0.0.1', r));

// 2) Chrome
const profile = await mkdtemp(path.join(os.tmpdir(), 'marklayer-native-zoom-'));
const chrome = spawn(
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  [
    `--remote-debugging-port=${CDP_PORT}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1280,900',
    '--window-position=120,60',
    `http://127.0.0.1:${PORT}/fixture.html`,
  ],
  { stdio: 'ignore' },
);

async function connect(url) {
  const ws = new WebSocket(url);
  await new Promise((ok, bad) => {
    ws.onopen = ok;
    ws.onerror = bad;
  });
  let id = 0;
  const pending = new Map();
  ws.onmessage = ({ data }) => {
    const m = JSON.parse(data);
    if (pending.has(m.id)) {
      const [ok, bad] = pending.get(m.id);
      pending.delete(m.id);
      m.error ? bad(Error(JSON.stringify(m.error))) : ok(m.result);
    }
  };
  return {
    send: (method, params = {}) =>
      new Promise((ok, bad) => {
        const n = ++id;
        pending.set(n, [ok, bad]);
        ws.send(JSON.stringify({ id: n, method, params }));
      }),
    close: () => ws.close(),
  };
}

let target;
for (let i = 0; i < 150; i++) {
  try {
    const list = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`)).json();
    target = list.find((t) => t.url.includes(`:${PORT}/fixture.html`) && t.type === 'page');
    if (target) break;
  } catch {}
  await sleep(100);
}
if (!target) {
  console.error('chrome page target not found');
  process.exit(2);
}
const page = await connect(target.webSocketDebuggerUrl);
await page.send('Runtime.enable');

const expr = `JSON.stringify({
  dpr: devicePixelRatio,
  scale: visualViewport ? visualViewport.scale : null,
  vvWidth: visualViewport ? visualViewport.width : null,
  innerWidth, innerHeight, outerWidth,
  t1: (()=>{const r=document.querySelector('#target').getBoundingClientRect();return {x:+r.x.toFixed(2),y:+r.y.toFixed(2),w:+r.width.toFixed(2),h:+r.height.toFixed(2)}})(),
  t2: (()=>{const r=document.querySelector('#target2').getBoundingClientRect();return {x:+r.x.toFixed(2),y:+r.y.toFixed(2),w:+r.width.toFixed(2),h:+r.height.toFixed(2)}})()
})`;

await writeFile(readingsPath, '');
let prev = '';
let shot = 0;
const started = Date.now();
const MAX_MS = 10 * 60 * 1000;
while (Date.now() - started < MAX_MS) {
  if (existsSync(stopPath)) break;
  let reading;
  try {
    const r = await page.send('Runtime.evaluate', { expression: expr, returnByValue: true });
    reading = JSON.parse(r.result.value);
  } catch (e) {
    await appendFile(readingsPath, `${JSON.stringify({ t: new Date().toISOString(), error: String(e) })}\n`);
    await sleep(500);
    continue;
  }
  const key = `${reading.dpr}|${reading.scale}|${reading.innerWidth}|${reading.t1.x}|${reading.t1.w}`;
  const rec = { t: new Date().toISOString(), ...reading, changed: key !== prev };
  await appendFile(readingsPath, `${JSON.stringify(rec)}\n`);
  if (key !== prev) {
    prev = key;
    shot += 1;
    try {
      const s = await page.send('Page.captureScreenshot');
      await writeFile(path.join(shotsDir, `${String(shot).padStart(2, '0')}-step.png`), Buffer.from(s.data, 'base64'));
    } catch {}
  }
  await sleep(400);
}

try {
  server.close();
} catch {}
try {
  chrome.kill();
} catch {}
console.log('done');
