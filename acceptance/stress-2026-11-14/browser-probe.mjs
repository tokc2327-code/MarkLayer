import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtemp, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const root = process.cwd();
const base = 'http://127.0.0.1:5199';
const room = `browser-${randomUUID()}`;
const chrome = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const extension = path.resolve('apps/extension/.output/chrome-mv3');
const log = [];
const processes = [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function cdp(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const [resolve, reject] = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result);
    }
  };
  return {
    send: (method, params = {}) =>
      new Promise((resolve, reject) => {
        const n = ++id;
        pending.set(n, [resolve, reject]);
        ws.send(JSON.stringify({ id: n, method, params }));
      }),
    close: () => ws.close(),
  };
}
await fetch(`${base}/api/${room}`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ ops: [], url: 'https://example.com', width: 1440 }),
});
try {
  const clients = await Promise.all(
    Array.from({ length: 6 }, async (_, i) => {
      const profile = await mkdtemp(path.join(os.tmpdir(), `marklayer-stress-${i}-`));
      const port = 19200 + i;
      const proc = spawn(
        chrome,
        [
          '--headless=new',
          '--enable-unsafe-extension-debugging',
          `--remote-debugging-port=${port}`,
          `--user-data-dir=${profile}`,
          '--no-first-run',
          '--no-default-browser-check',
          'about:blank',
        ],
        { stdio: 'ignore' },
      );
      processes.push(proc);
      let version;
      for (let j = 0; j < 100; j++) {
        try {
          version = await fetch(`http://127.0.0.1:${port}/json/version`).then((r) => r.json());
          break;
        } catch {
          await sleep(100);
        }
      }
      if (!version) throw new Error(`Chrome ${i} failed to start`);
      const browser = await cdp(version.webSocketDebuggerUrl);
      const installed = await browser.send('Extensions.loadUnpacked', { path: extension });
      const target = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(`${base}/s/${room}`)}`, {
        method: 'PUT',
      }).then((r) => r.json());
      const page = await cdp(target.webSocketDebuggerUrl);
      await page.send('Page.enable');
      await page.send('Runtime.enable');
      log.push({ client: i, profile, extensionId: installed.id, version: version.Browser });
      return { page, browser, i };
    }),
  );
  await sleep(12000);
  await Promise.all(
    clients.map(async ({ page, i }) => {
      const state = await page.send('Runtime.evaluate', {
        expression:
          'JSON.stringify({title:document.title,text:document.body.innerText.slice(0,5000),url:location.href})',
        returnByValue: true,
      });
      const shot = await page.send('Page.captureScreenshot');
      if (i === 0)
        await writeFile(path.join(root, 'acceptance/stress-2026-11-14/browser.png'), Buffer.from(shot.data, 'base64'));
      log.push({ client: i, state: state.result.value });
      for (const [type, x, y] of [
        ['mouseMoved', 500, 350],
        ['mousePressed', 500, 350],
        ['mouseMoved', 600, 400],
        ['mouseReleased', 600, 400],
      ])
        await page.send('Input.dispatchMouseEvent', {
          type,
          x,
          y,
          button: type === 'mouseMoved' ? 'none' : 'left',
          buttons: type === 'mouseReleased' ? 0 : 1,
          clickCount: 1,
        });
      for (const [x, y] of [
        [327, 450],
        [400 + i * 5, 250],
      ]) {
        for (const type of ['mousePressed', 'mouseReleased'])
          await page.send('Input.dispatchMouseEvent', {
            type,
            x,
            y,
            button: 'left',
            buttons: type === 'mousePressed' ? 1 : 0,
            clickCount: 1,
          });
      }
      await sleep(1000);
      const after = await page.send('Page.captureScreenshot');
      if (i === 0)
        await writeFile(
          path.join(root, 'acceptance/stress-2026-11-14/browser-comment.png'),
          Buffer.from(after.data, 'base64'),
        );
      log.push({
        client: i,
        after: (await page.send('Runtime.evaluate', { expression: 'document.body.innerText', returnByValue: true }))
          .result.value,
      });
      for (const type of ['mousePressed', 'mouseReleased'])
        await page.send('Input.dispatchMouseEvent', {
          type,
          x: 120,
          y: 380,
          button: 'left',
          buttons: type === 'mousePressed' ? 1 : 0,
          clickCount: 1,
        });
      await page.send('Input.insertText', { text: `browser-comment-${i}` });
      for (const type of ['mousePressed', 'mouseReleased'])
        await page.send('Input.dispatchMouseEvent', {
          type,
          x: 725,
          y: 460,
          button: 'left',
          buttons: type === 'mousePressed' ? 1 : 0,
          clickCount: 1,
        });
    }),
  );
  await sleep(3000);
  log.push({ snapshot: await fetch(`${base}/api/${room}`).then((r) => r.text()) });
  await clients[0].page.send('Network.enable');
  await clients[0].page.send('Network.emulateNetworkConditions', {
    offline: true,
    latency: 0,
    downloadThroughput: 0,
    uploadThroughput: 0,
  });
  await sleep(30000);
  await clients[0].page.send('Network.emulateNetworkConditions', {
    offline: false,
    latency: 0,
    downloadThroughput: -1,
    uploadThroughput: -1,
  });
  await sleep(5000);
  log.push({ afterReconnect: await fetch(`${base}/api/${room}`).then((r) => r.text()) });
  for (const c of clients) {
    c.page.close();
    c.browser.close();
  }
} catch (error) {
  log.push({ error: String(error) });
  process.exitCode = 1;
} finally {
  for (const p of processes) p.kill();
  await writeFile(new URL('./browser-raw.json', import.meta.url), JSON.stringify({ room, log }, null, 2));
}
