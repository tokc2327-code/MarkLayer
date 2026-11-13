import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const out = 'acceptance/zoom-2026-11-14';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function connect(url) {
  const ws = new WebSocket(url);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let id = 0; const pending = new Map();
  ws.onmessage = ({ data }) => { const m = JSON.parse(data); if (pending.has(m.id)) { const [ok, fail] = pending.get(m.id); pending.delete(m.id); m.error ? fail(Error(JSON.stringify(m.error))) : ok(m.result); } };
  return { send: (method, params = {}) => new Promise((ok, fail) => { const n = ++id; pending.set(n, [ok, fail]); ws.send(JSON.stringify({ id: n, method, params })); }), close: () => ws.close() };
}
const result = { steps: [] };
const profile = await mkdtemp(path.join(os.tmpdir(), 'marklayer-zoom-native-'));
const proc = spawn('C:/Program Files/Google/Chrome/Application/chrome.exe', ['--enable-unsafe-extension-debugging', '--remote-debugging-port=19455', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--window-size=1280,900', 'http://127.0.0.1:8791/fixture.html'], { stdio: 'ignore' });
try {
  let version; for (let i = 0; i < 100; i++) { try { version = await (await fetch('http://127.0.0.1:19455/json/version')).json(); break; } catch { await sleep(100); } }
  if (!version) throw Error('Chrome CDP endpoint did not start');
  result.browser = version.Browser;
  const browser = await connect(version.webSocketDebuggerUrl);
  result.extension = await browser.send('Extensions.loadUnpacked', { path: path.resolve('apps/extension/.output/chrome-mv3') });
  const targets = await (await fetch('http://127.0.0.1:19455/json/list')).json();
  const target = targets.find((t) => t.url.includes('8791/fixture.html'));
  if (!target) throw Error('fixture target missing');
  const page = await connect(target.webSocketDebuggerUrl);
  await page.send('Page.enable'); await page.send('Runtime.enable');
  await sleep(1000);
  async function record(name) {
    const v = await page.send('Runtime.evaluate', { expression: `JSON.stringify({dpr:devicePixelRatio,scale:visualViewport.scale,width:innerWidth,height:innerHeight,target:(()=>{let r=document.querySelector('#target').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})()})`, returnByValue: true });
    const shot = await page.send('Page.captureScreenshot');
    await writeFile(`${out}/${name}.png`, Buffer.from(shot.data, 'base64'));
    result.steps.push({ name, ...JSON.parse(v.result.value) });
  }
  await record('01-baseline');
  const focus = spawnSync('powershell', ['-NoProfile', '-Command', `$w = New-Object -ComObject WScript.Shell; $w.AppActivate(${proc.pid})`], { encoding: 'utf8' });
  result.focus = { stdout: focus.stdout.trim(), stderr: focus.stderr.trim() };
  await sleep(500);
  for (const [name, keys] of [['05-native-plus-one', '^{=}' ], ['06-native-plus-two', '^{=}'], ['07-native-minus-one', '^{-}'], ['08-native-minus-two', '^{-}'], ['09-native-minus-three', '^{-}'], ['10-native-minus-four', '^{-}'], ['11-native-reset', '^0']]) {
    const sent = spawnSync('powershell', ['-NoProfile', '-Command', `Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('${keys}')`], { encoding: 'utf8' });
    if (sent.status !== 0) throw Error(`SendKeys ${name}: ${sent.stderr}`);
    await sleep(500); await record(name);
  }
  for (const [name, key, code, vk] of [['02-ctrl-equals','=', 'Equal',187], ['03-ctrl-minus','-', 'Minus',189], ['04-ctrl-zero','0','Digit0',48]]) {
    await page.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Control', code: 'ControlLeft', windowsVirtualKeyCode: 17, modifiers: 2 });
    await page.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key, code, windowsVirtualKeyCode: vk, modifiers: 2 });
    await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: vk, modifiers: 2 });
    await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Control', code: 'ControlLeft', windowsVirtualKeyCode: 17 });
    await sleep(600); await record(name);
  }
  page.close(); browser.close();
} catch (error) { result.error = String(error); process.exitCode = 1; }
finally { proc.kill(); await writeFile(`${out}/probe.json`, JSON.stringify(result, null, 2)); }
