import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readdir, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const base = process.env.STRESS_BASE ?? 'http://127.0.0.1:5297';
const room = `round2-${randomUUID()}`;
const roomB = `round2b-${randomUUID()}`;
const log = { room, roomB, clients: [], events: [], checks: [] };
const processes = [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const out = new URL('./round4-offline-raw.json', import.meta.url);
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
    Array.from({ length: 6 }, async (_, i) => {
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
      await page.send('Page.navigate', { url: `${base}/s/${room}` });
      log.clients.push({ i, profile, extension: ext.id, version: v.Browser });
      return { i, browser, page };
    }),
  );
  await sleep(12000);
  for (const c of clients) log.checks.push({ stage: 'initial', client: c.i, ops: await dump(c) });
  const a = clients[0];
  const info = await evalPage(
    a,
    `JSON.stringify([...document.querySelectorAll('button')].map(b=>({text:b.innerText, title:b.title, aria:b.getAttribute('aria-label')})))`,
  );
  log.checks.push({ stage: 'buttons', value: info.value });
  const shot = await a.page.send('Page.captureScreenshot');
  await writeFile(new URL('./round4-initial.png', import.meta.url), Buffer.from(shot.data, 'base64'));
  // Open Threads, then locate the board through visible controls.
  await Promise.all(clients.map((c) => click(c, 400, 450)));
  await sleep(2500);
  log.checks.push({
    stage: 'after-threads',
    value: (
      await evalPage(
        a,
        `JSON.stringify([...document.querySelectorAll('button')].map(b=>({text:b.innerText,title:b.title,aria:b.getAttribute('aria-label'),rect:(()=>{let r=b.getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()})))`,
      )
    ).value,
  });
  const shot2 = await a.page.send('Page.captureScreenshot');
  await writeFile(new URL('./round4-threads.png', import.meta.url), Buffer.from(shot2.data, 'base64'));
  await Promise.all(clients.map((c) => click(c, 692, 266)));
  await sleep(1000);
  log.checks.push({
    stage: 'menu',
    value: (
      await evalPage(
        a,
        `JSON.stringify([...document.querySelectorAll('[role=menuitem],button')].map(b=>({text:b.innerText,title:b.title,aria:b.getAttribute('aria-label'),rect:(()=>{let r=b.getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()})).filter(x=>x.rect[2]>0))`,
      )
    ).value,
  });
  const shot3 = await a.page.send('Page.captureScreenshot');
  await writeFile(new URL('./round4-menu.png', import.meta.url), Buffer.from(shot3.data, 'base64'));
  await Promise.all(clients.map((c) => click(c, 540, 450)));
  await sleep(1500);
  log.checks.push({
    stage: 'board',
    value: (
      await evalPage(
        a,
        `JSON.stringify([...document.querySelectorAll('section,article,[data-card]')].map(b=>({tag:b.tagName,text:b.innerText.slice(0,100),card:b.getAttribute('data-card'),rect:(()=>{let r=b.getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()})))`,
      )
    ).value,
  });
  const shot4 = await a.page.send('Page.captureScreenshot');
  await writeFile(new URL('./round4-board.png', import.meta.url), Buffer.from(shot4.data, 'base64'));
  // Each pointer is pressed before either is released, on the same card.
  await Promise.all([clients[0], clients[1]].map((c) => mouse(c, 'mouseMoved', 140, 150)));
  await Promise.all([clients[0], clients[1]].map((c) => mouse(c, 'mousePressed', 140, 150, 1)));
  for (const x of [160, 210, 280, 340, 400]) {
    await Promise.all([clients[0], clients[1]].map((c) => mouse(c, 'mouseMoved', x, 160, 1)));
    await sleep(150);
  }
  await Promise.all([mouse(clients[0], 'mouseReleased', 400, 160), mouse(clients[1], 'mouseReleased', 400, 160)]);
  await sleep(3000);
  for (const c of clients) log.checks.push({ stage: 'after-drag', client: c.i, ops: await dump(c) });
  // Invalid layer causes the actual optimistic client pipeline to receive a server refusal.
  const invalid = `(async()=>{const m=await import(${JSON.stringify(mod)});const before=structuredClone(m.m.value);const applied=m.t({type:'update_op',opId:${JSON.stringify(seedOp.id)},patch:{layerId:'does-not-exist'}},{origin:'local'});return JSON.stringify({applied,before,optimistic:structuredClone(m.m.value)});})()`;
  log.checks.push({ stage: 'invalid-optimistic', client: 0, value: (await evalPage(a, invalid)).value });
  await sleep(2500);
  log.checks.push({
    stage: 'invalid-after',
    client: 0,
    ops: await dump(a),
    text: (await evalPage(a, 'document.body.innerText')).value,
  });
  await a.page.send('Network.emulateNetworkConditions', {
    offline: true,
    latency: 0,
    downloadThroughput: 0,
    uploadThroughput: 0,
  });
  log.checks.push({ stage: 'offline-start', at: Date.now() });
  // Existing WebSockets can survive CDP offline emulation; close this socket so
  // reconnect attempts actually occur while the network is disabled.
  log.checks.push({
    stage: 'offline-close',
    value: (
      await evalPage(
        a,
        `(()=>{const s=window.__stressRoomSocket;const readyState=s?.readyState;s?.close();return readyState})()`,
      )
    ).value,
  });
  await sleep(22000);
  // Add a unique op using the real application's local mutation pipeline.
  const c = clients[2];
  const newOps = Array.from({ length: 20 }, (_, i) => ({
    ...seedOp,
    id: `offline-${randomUUID()}`,
    text: `offline peer write ${i}`,
  }));
  const writeExpr = `(async()=>{const m=await import(${JSON.stringify(mod)});return ${JSON.stringify(newOps)}.map(op=>m.t({type:'op',op},{origin:'local'}));})()`;
  log.checks.push({
    stage: 'offline-peer-write-attempt',
    at: Date.now(),
    applied: (await evalPage(c, writeExpr)).value,
    ids: newOps.map((op) => op.id),
    ops: await dump(c),
  });
  log.checks.push({ stage: 'offline-client-before-recovery', at: Date.now(), ops: await dump(a) });
  await sleep(8000);
  await a.page.send('Network.emulateNetworkConditions', {
    offline: false,
    latency: 0,
    downloadThroughput: -1,
    uploadThroughput: -1,
  });
  log.checks.push({ stage: 'offline-end', at: Date.now() });
  await sleep(12000);
  const recoveredOps = Array.from({ length: 10 }, (_, i) => ({
    ...seedOp,
    id: `recovered-${randomUUID()}`,
    text: `recovered client write ${i}`,
  }));
  const recoveredExpr = `(async()=>{const m=await import(${JSON.stringify(mod)});return ${JSON.stringify(recoveredOps)}.map(op=>m.t({type:'op',op},{origin:'local'}));})()`;
  log.checks.push({
    stage: 'recovered-writes',
    at: Date.now(),
    applied: (await evalPage(a, recoveredExpr)).value,
    ids: recoveredOps.map((op) => op.id),
  });
  await sleep(4000);
  for (const c of clients) log.checks.push({ stage: 'final-room-a', client: c.i, ops: await dump(c) });
  log.checks.push({ stage: 'server-a', body: await fetch(`${base}/api/${room}`).then((r) => r.json()) });
  await clients[5].page.send('Page.navigate', { url: `${base}/s/${roomB}` });
  await sleep(8000);
  log.checks.push({ stage: 'client-room-b', client: 5, ops: await dump(clients[5]) });
  log.checks.push({ stage: 'server-b', body: await fetch(`${base}/api/${roomB}`).then((r) => r.json()) });
  log.checks.push({ stage: 'client-room-a-again', client: 1, ops: await dump(clients[1]) });
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
