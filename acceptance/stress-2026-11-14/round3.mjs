import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readdir, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const base = 'http://127.0.0.1:5199';
const room = `round2-${randomUUID()}`;
const roomB = `round2b-${randomUUID()}`;
const log = { room, roomB, clients: [], events: [], checks: [] };
const processes = [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const out = new URL('./round3-raw.json', import.meta.url);
const fixture = JSON.parse(await readFile(new URL('./browser-raw.json', import.meta.url), 'utf8'));
const seedOp = JSON.parse(fixture.log.find((x) => x.afterReconnect).afterReconnect).ops[0];
seedOp.id = `seed-${randomUUID()}`;
seedOp.text = 'round2 shared card';
seedOp.attachments = [];
delete seedOp.target;
for (const [id, ops] of [
  [room, [seedOp]],
  [roomB, [{ ...seedOp, id: `other-${randomUUID()}`, text: 'room-B-only' }]],
]) {
  const r = await fetch(`${base}/api/${id}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ ops, url: 'https://example.com', width: 1440 }),
  });
  if (!r.ok) throw Error(`seed ${r.status} ${await r.text()}`);
}
const file = (await readdir('apps/worker/public/client/assets')).find((x) => /^ops-.*\.js$/.test(x));
const mod = `${base}/assets/${file}`;
function connect(url, i) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    let n = 0;
    const pending = new Map();
    ws.onerror = reject;
    ws.onopen = () =>
      resolve({
        send(method, params = {}) {
          return new Promise((res, rej) => {
            const id = ++n;
            pending.set(id, [res, rej]);
            ws.send(JSON.stringify({ id, method, params }));
          });
        },
        close() {
          ws.close();
        },
      });
    ws.onmessage = (e) => {
      const m = JSON.parse(e.data);
      if (m.id && pending.has(m.id)) {
        const [res, rej] = pending.get(m.id);
        pending.delete(m.id);
        m.error ? rej(Error(JSON.stringify(m.error))) : res(m.result);
      } else if (m.method?.startsWith('Network.webSocket'))
        log.events.push({ client: i, method: m.method, params: m.params, at: Date.now() });
    };
  });
}
const evalPage = async (c, expression) =>
  (await c.page.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result;
const dump = async (c) => {
  const r = await evalPage(c, `(async()=>JSON.stringify((await import(${JSON.stringify(mod)})).m.value))()`);
  if (r.subtype === 'error') throw Error(JSON.stringify(r));
  return JSON.parse(r.value);
};
const mouse = (c, type, x, y, buttons = 0) =>
  c.page.send('Input.dispatchMouseEvent', {
    type,
    x,
    y,
    button: type === 'mouseMoved' && !buttons ? 'none' : 'left',
    buttons,
    clickCount: 1,
  });
const click = async (c, x, y) => {
  await mouse(c, 'mousePressed', x, y, 1);
  await mouse(c, 'mouseReleased', x, y);
};
try {
  const clients = await Promise.all(
    Array.from({ length: 4 }, async (_, i) => {
      const profile = await mkdtemp(path.join(os.tmpdir(), `ml-round2-${i}-`));
      const port = 19400 + i;
      const proc = spawn(
        'C:/Program Files/Google/Chrome/Application/chrome.exe',
        [
          '--headless=new',
          '--enable-unsafe-extension-debugging',
          `--remote-debugging-port=${port}`,
          `--user-data-dir=${profile}`,
          '--no-first-run',
          'about:blank',
        ],
        { stdio: 'ignore' },
      );
      processes.push(proc);
      let v;
      for (let j = 0; j < 100; j++) {
        try {
          v = await fetch(`http://127.0.0.1:${port}/json/version`).then((r) => r.json());
          break;
        } catch {
          await sleep(100);
        }
      }
      if (!v) throw Error('chrome start');
      const browser = await connect(v.webSocketDebuggerUrl, i);
      const ext = await browser.send('Extensions.loadUnpacked', {
        path: path.resolve('apps/extension/.output/chrome-mv3'),
      });
      const target = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' }).then((r) =>
        r.json(),
      );
      const page = await connect(target.webSocketDebuggerUrl, i);
      await page.send('Network.enable');
      await page.send('Page.enable');
      await page.send('Runtime.enable');
      await page.send('Page.addScriptToEvaluateOnNewDocument', {
        source: `(()=>{const Native=window.WebSocket;window.WebSocket=new Proxy(Native,{construct(target,args){const ws=Reflect.construct(target,args);if(String(args[0]).includes('/ws/'))window.__stressRoomSocket=ws;return ws;}})})()`,
      });
      await page.send('Page.navigate', { url: `${base}/s/${i < 2 ? room : roomB}` });
      log.clients.push({ i, profile, extension: ext.id, version: v.Browser });
      return { i, browser, page };
    }),
  );
  await sleep(12000);
  for (const c of clients) log.checks.push({ stage: 'initial', client: c.i, ops: await dump(c) });
  const makeWrite = (op) =>
    `(async()=>{const m=await import(${JSON.stringify(mod)});return m.t({type:'op',op:${JSON.stringify(op)}},{origin:'local'});})()`;
  const writes = clients.map((c, i) => ({
    ...seedOp,
    id: `r3-${i}-${randomUUID()}`,
    text: `room-${i < 2 ? 'A' : 'B'}-write-${i}`,
  }));
  log.checks.push({
    stage: 'writes',
    at: Date.now(),
    values: await Promise.all(clients.map((c, i) => evalPage(c, makeWrite(writes[i])))),
  });
  await sleep(3000);
  const update = (value) =>
    `(async()=>{const m=await import(${JSON.stringify(mod)});return m.t({type:'update_op',opId:${JSON.stringify(seedOp.id)},patch:{text:${JSON.stringify(value)}}},{origin:'local'});})()`;
  log.checks.push({
    stage: 'conflict-attempt',
    at: Date.now(),
    values: await Promise.all([
      evalPage(clients[0], update('concurrent-0')),
      evalPage(clients[1], update('concurrent-1')),
    ]),
  });
  await sleep(3000);
  for (const c of clients) log.checks.push({ stage: 'after-writes', client: c.i, ops: await dump(c) });
  for (const [label, id] of [
    ['a', room],
    ['b', roomB],
  ])
    log.checks.push({ stage: `server-${label}`, body: await fetch(`${base}/api/${id}`).then((r) => r.json()) });
  // Repeated actual socket closure and observed reinitialization.
  for (let n = 0; n < 5; n++) {
    const start = Date.now();
    await evalPage(clients[0], `window.__stressRoomSocket.close()`);
    let ready = false;
    for (let j = 0; j < 100; j++) {
      await sleep(100);
      if (
        log.events.some(
          (e) =>
            e.client === 0 &&
            e.at >= start &&
            e.method === 'Network.webSocketFrameReceived' &&
            (() => {
              try {
                return JSON.parse(e.params.response.payloadData).type === 'init';
              } catch {
                return false;
              }
            })(),
        )
      ) {
        ready = true;
        break;
      }
    }
    log.checks.push({ stage: 'reconnect', start, end: Date.now(), ready });
  }
  for (const c of clients) {
    c.page.close();
    c.browser.close();
  }
} catch (e) {
  log.error = String(e);
  process.exitCode = 1;
} finally {
  for (const p of processes) p.kill();
  await writeFile(out, JSON.stringify(log, null, 2));
}
