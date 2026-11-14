import { spawn } from 'node:child_process';
import { cp, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import os from 'node:os';
import path from 'node:path';

const root = process.cwd(),
  tmp = await mkdtemp(path.join(os.tmpdir(), 'pair-e2e-'));
const ext = path.join(tmp, 'extension'),
  base = 'http://127.0.0.1:19480',
  fixture = 'http://127.0.0.1:19481/',
  room = 'pairpresence20261114';
const sleep = (n) => new Promise((r) => setTimeout(r, n));
const output = { kind: 'Chrome CDP', steps: [] },
  children = [];
let server, browser, page, workerTarget;
async function wait(url) {
  for (let i = 0; i < 150; i++) {
    try {
      const r = await fetch(url);
      if (r.ok) return r;
    } catch {}
    await sleep(200);
  }
  throw Error(`unavailable ${url}`);
}
async function cdp(url) {
  const ws = new WebSocket(url);
  await new Promise((r, j) => {
    ws.onopen = r;
    ws.onerror = j;
  });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    const p = pending.get(m.id);
    if (p) {
      pending.delete(m.id);
      m.error ? p[1](Error(JSON.stringify(m.error))) : p[0](m.result);
    }
  };
  return {
    send: (method, params = {}) =>
      new Promise((r, j) => {
        const n = ++id;
        const t = setTimeout(() => {
          pending.delete(n);
          j(Error('CDP timeout ' + method));
        }, 8000);
        pending.set(n, [
          (v) => {
            clearTimeout(t);
            r(v);
          },
          (e) => {
            clearTimeout(t);
            j(e);
          },
        ]);
        ws.send(JSON.stringify({ id: n, method, params }));
      }),
    close: () => ws.close(),
  };
}
async function tool() {
  const response = await fetch(`${base}/s/${room}/mcp?agent=presence-test`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: 'marklayer_room_presence', arguments: {} },
    }),
  });
  const raw = await response.text();
  const line = raw.split('\n').find((x) => x.startsWith('data: '));
  const value = JSON.parse(line ? line.slice(6) : raw);
  if (!response.ok || value.error || value.result?.isError) throw Error(`MCP ${response.status} ${raw}`);
  return JSON.parse(value.result.content[0].text);
}
try {
  await cp(path.resolve('apps/extension/.output/chrome-mv3'), ext, { recursive: true });
  const manifest = JSON.parse(await readFile(path.join(ext, 'manifest.json'), 'utf8'));
  manifest.host_permissions = ['http://127.0.0.1/*'];
  await writeFile(path.join(ext, 'manifest.json'), JSON.stringify(manifest));
  const file = path.join(ext, 'content-scripts/content.js');
  const js = await readFile(file, 'utf8');
  await writeFile(file, js.replaceAll('https://marklayer.app', base));
  server = createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end('<!doctype html><title>Presence fixture</title><div style="height:4000px">Fixture</div>');
  });
  await new Promise((r) => server.listen(19481, '127.0.0.1', r));
  const proc = spawn(
    process.execPath,
    [
      path.join(root, 'node_modules/wrangler/bin/wrangler.js'),
      'dev',
      '--local',
      '--port',
      '19480',
      '--persist-to',
      path.join(os.tmpdir(), 'pair-presence-local-20261114'),
    ],
    { cwd: path.join(root, 'apps/worker'), stdio: 'ignore' },
  );
  children.push(proc);
  await wait(base + '/');
  const seed = await fetch(`${base}/api/${room}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ ops: [], url: fixture, width: 1280 }),
  });
  if (!seed.ok) throw Error(`seed ${seed.status}: ${await seed.text()}`);
  const chrome = spawn(
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    [
      '--headless=new',
      '--enable-unsafe-extension-debugging',
      '--remote-debugging-port=19479',
      `--user-data-dir=${path.join(tmp, 'profile')}`,
      '--no-first-run',
      'about:blank',
    ],
    { stdio: 'ignore' },
  );
  children.push(chrome);
  const version = await (await wait('http://127.0.0.1:19479/json/version')).json();
  browser = await cdp(version.webSocketDebuggerUrl);
  const installed = await browser.send('Extensions.loadUnpacked', { path: ext });
  output.steps.push({
    chrome: version.Browser,
    extension: installed.id,
    temporaryChanges: 'local API origin and localhost host permission',
  });
  const target = await (
    await fetch(`http://127.0.0.1:19479/json/new?${encodeURIComponent(fixture + '#ant=1280=' + room)}`, {
      method: 'PUT',
    })
  ).json();
  page = await cdp(target.webSocketDebuggerUrl);
  await page.send('Page.enable');
  await page.send('Runtime.enable');
  let service;
  for (let i = 0; i < 60; i++) {
    const targets = await (await fetch('http://127.0.0.1:19479/json/list')).json();
    service = targets.find((x) => x.type === 'service_worker' && x.url.includes(installed.id));
    if (service) break;
    await sleep(100);
  }
  if (!service) throw Error('extension service worker unavailable');
  workerTarget = await cdp(service.webSocketDebuggerUrl);
  output.steps.push({
    workerProbe: await workerTarget.send('Runtime.evaluate', { expression: '1+1', returnByValue: true }),
  });
  const injection = await workerTarget.send('Runtime.evaluate', {
    expression: `(async()=>{const tabs=await chrome.tabs.query({});const tab=tabs.find(t=>t.url?.includes('19481'));await chrome.scripting.executeScript({target:{tabId:tab.id},files:['content-scripts/content.js']});return tab.id})()`,
    awaitPromise: true,
    returnByValue: true,
  });
  if (injection.exceptionDetails) throw Error(JSON.stringify(injection.exceptionDetails));
  output.steps.push({ injected: injection.result.value });
  let initial;
  for (let i = 0; i < 60; i++) {
    initial = await tool();
    if (initial.members?.length) break;
    await sleep(250);
  }
  if (!initial.members?.length) throw Error('no presence after injection');
  await page.send('Runtime.evaluate', { expression: 'window.scrollTo(0,700)' });
  await page.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 120, y: 180 });
  await sleep(400);
  const moved = await tool();
  output.steps.push({ moved });
  await page.send('Page.setWebLifecycleState', { state: 'frozen' });
  await sleep(11000);
  const stale = await tool();
  output.steps.push({ stale });
  await page.send('Page.setWebLifecycleState', { state: 'active' });
  if (moved.members[0]?.cursor?.y !== 880 || !stale.members[0]?.stale)
    throw Error('coordinate or stale assertion failed');
  await page.send('Page.navigate', { url: fixture });
  await sleep(1000);
  const departed = await tool();
  output.steps.push({ departed });
  if (departed.members.length) throw Error('presence remained after navigation');
  output.ok = true;
} catch (e) {
  output.error = String(e);
  process.exitCode = 1;
} finally {
  workerTarget?.close();
  page?.close();
  browser?.close();
  server?.close();
  for (const child of children) child.kill();
  await writeFile(
    path.join(root, 'acceptance/pair-presence-2026-11-14/chrome-result.json'),
    JSON.stringify(output, null, 2),
  );
  console.log(JSON.stringify(output));
}
