import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const ACCEPT_DIR = join(ROOT, 'acceptance', 'desktop-annotation-2026-11-14');
const DRIVER = join(ACCEPT_DIR, 'win32-driver.ps1');
const FIXTURE = join(ACCEPT_DIR, 'fixture-window.ps1');
const CLI = join(ROOT, 'packages', 'desktop-uia', 'cli.mjs');
const CHROME_EXE = 'C:/Program Files/Google/Chrome/Application/chrome.exe';

const PORT = 5185;
const CDP_PORT = 9335;
const BASE = `http://127.0.0.1:${PORT}`;
const TS = Date.now().toString(36);
const ROOM_ID = `deskaccept-${TS}-${randomUUID().slice(0, 6)}`;
const WEB_ROOM_ID = `webaccept-${TS}-${randomUUID().slice(0, 6)}`;
const PWD_ROOM_ID = `deskaccept-pwd-${TS}-${randomUUID().slice(0, 4)}`;
const PWD_SECRET = 'desktop-secret-4401';

function readJsonClean(path) {
  return JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''));
}

function runPsDriver(args) {
  const res = spawnSync(
    'powershell.exe',
    ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', DRIVER, ...args],
    { cwd: ROOT, encoding: 'utf8' },
  );
  if (res.status !== 0) {
    throw new Error(`win32-driver ${args.join(' ')} failed (${res.status}): ${res.stderr || res.stdout}`);
  }
  return JSON.parse(res.stdout.replace(/^\uFEFF/, '').trim());
}

function runCli(args, { expectFail = false } = {}) {
  const res = spawnSync('node', [CLI, ...args], { cwd: ROOT, encoding: 'utf8' });
  if (!expectFail && res.status !== 0) {
    throw new Error(`cli.mjs ${args.join(' ')} failed (${res.status}): ${res.stderr || res.stdout}`);
  }
  if (expectFail && res.status === 0) {
    throw new Error(`cli.mjs ${args.join(' ')} unexpectedly succeeded: ${res.stdout}`);
  }
  return res;
}

function killTree(pid) {
  if (!pid) return;
  spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
}

async function waitFor(fn, { timeoutMs = 15000, intervalMs = 100, label = 'condition' } = {}) {
  const deadline = Date.now() + timeoutMs;
  let lastErr;
  while (Date.now() < deadline) {
    try {
      const v = await fn();
      if (v) return v;
    } catch (err) {
      lastErr = err;
    }
    await delay(intervalMs);
  }
  throw new Error(`Timed out waiting for ${label}${lastErr ? `: ${lastErr.message}` : ''}`);
}

function rectsIntersect(a, b) {
  return !(
    a.left + a.width <= b.left ||
    b.left + b.width <= a.left ||
    a.top + a.height <= b.top ||
    b.top + b.height <= a.top
  );
}

async function mcpHttp(roomId, name, args, extraHeaders = {}) {
  const res = await fetch(`${BASE}/s/${roomId}/mcp?agent=accept-agent`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', ...extraHeaders },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }),
  });
  const raw = await res.text();
  const dataLine = raw.split('\n').find((l) => l.startsWith('data: '));
  const payload = dataLine ? JSON.parse(dataLine.slice(6)) : JSON.parse(raw);
  if (!res.ok || payload.error || payload.result?.isError) {
    throw new Error(`MCP ${name} failed (${res.status}): ${raw}`);
  }
  const textPart = payload.result?.content?.find((c) => c.type === 'text')?.text;
  return textPart ? JSON.parse(textPart) : payload.result;
}

class CdpClient {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.consoleErrors = [];
    this.pageErrors = [];
    this.ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(String(ev.data));
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve: res, reject: rej } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) rej(new Error(msg.error.message));
        else res(msg.result);
      } else if (msg.method === 'Runtime.exceptionThrown') {
        this.pageErrors.push(msg.params?.exceptionDetails?.text ?? 'Runtime exception');
      } else if (msg.method === 'Runtime.consoleAPICalled' && msg.params?.type === 'error') {
        this.consoleErrors.push(msg.params.args?.map((a) => a.value ?? a.description).join(' ') ?? 'console.error');
      }
    });
  }
  async open() {
    await new Promise((res, rej) => {
      this.ws.addEventListener('open', res, { once: true });
      this.ws.addEventListener('error', rej, { once: true });
    });
    await this.send('Page.enable');
    await this.send('Runtime.enable');
  }
  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((res, rej) => {
      this.pending.set(id, { resolve: res, reject: rej });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async evaluate(expression) {
    const out = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (out.exceptionDetails) throw new Error(`CDP eval error: ${out.exceptionDetails.text}`);
    return out.result?.value;
  }
  close() {
    try {
      this.ws.close();
    } catch {}
  }
}

mkdirSync(ACCEPT_DIR, { recursive: true });
const workDir = mkdtempSync(join(tmpdir(), 'ml-desktop-accept-'));
const chromeDir = join(workDir, 'chrome-profile');
const fixtureStatePath = join(workDir, 'fixture-state.json');
const overlayStatePath = join(workDir, 'overlay-state.json');
const targetSavePath = join(workDir, 'target-save.json');

let workerProc = null;
let fixtureProc = null;
let overlayProc = null;
let chromeProc = null;
let cdp = null;

const report = {
  timestamp: new Date().toISOString(),
  roomId: ROOM_ID,
  webRoomId: WEB_ROOM_ID,
  pwdRoomId: PWD_ROOM_ID,
  environment: runPsDriver(['-Action', 'session-info']),
  steps: {},
};

try {
  // 1. Apply D1 migrations to an isolated persist-to dir and start local Worker (wrangler dev --local)
  const wranglerStateDir = join(workDir, 'wrangler-state');
  const migRes = spawnSync(
    process.execPath,
    [
      join(ROOT, 'node_modules', 'wrangler', 'bin', 'wrangler.js'),
      'd1',
      'migrations',
      'apply',
      'marklayer',
      '--local',
      '--persist-to',
      wranglerStateDir,
    ],
    {
      cwd: join(ROOT, 'apps', 'worker'),
      input: 'y\n',
      encoding: 'utf8',
    },
  );
  if (migRes.status !== 0) {
    throw new Error(`D1 migrations apply failed (${migRes.status}): ${migRes.stderr || migRes.stdout}`);
  }

  workerProc = spawn(
    process.execPath,
    [
      join(ROOT, 'node_modules', 'wrangler', 'bin', 'wrangler.js'),
      'dev',
      '--local',
      '--ip',
      '127.0.0.1',
      '--port',
      String(PORT),
      '--persist-to',
      wranglerStateDir,
    ],
    {
      cwd: join(ROOT, 'apps', 'worker'),
      stdio: ['ignore', 'pipe', 'pipe'],
      shell: false,
    },
  );
  let workerLog = '';
  workerProc.stdout.on('data', (d) => {
    workerLog += d.toString();
  });
  workerProc.stderr.on('data', (d) => {
    workerLog += d.toString();
  });

  await waitFor(
    async () => {
      if (workerProc.exitCode !== null) throw new Error(`Worker exited early (${workerProc.exitCode}): ${workerLog}`);
      const r = await fetch(`${BASE}/api/${ROOM_ID}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ ops: [], width: 1280 }),
      });
      if (!r.ok) throw new Error(`POST /api/${ROOM_ID} -> ${r.status}: ${await r.text()}`);
      return true;
    },
    { timeoutMs: 45000, intervalMs: 400, label: 'local Worker ready & desktop room created' },
  ).catch((err) => {
    throw new Error(`${err.message}\n--- workerLog ---\n${workerLog}`);
  });

  // Seed a classic web room too (regression sanity check)
  const webSeed = await fetch(`${BASE}/api/${WEB_ROOM_ID}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      url: 'https://example.com',
      width: 1280,
      ops: [
        {
          id: 'web-seed-1',
          tool: 'comment',
          num: 1,
          x: 240,
          y: 160,
          color: '#ef4444',
          lineWidth: 2,
          text: 'Web baseline note',
          author: 'Web Reviewer',
          ts: Date.now(),
        },
      ],
    }),
  });
  if (!webSeed.ok) throw new Error(`Web seed failed (${webSeed.status}): ${await webSeed.text()}`);

  // 2. Launch self-built WinForms fixture window
  fixtureProc = spawn(
    'powershell.exe',
    [
      '-NoProfile',
      '-STA',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      FIXTURE,
      '-X',
      '180',
      '-Y',
      '140',
      '-ReadyPath',
      fixtureStatePath,
    ],
    { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] },
  );
  const fixture0 = await waitFor(() => readJsonClean(fixtureStatePath), {
    timeoutMs: 10000,
    label: 'fixture window state',
  });
  const fixturePid = fixture0.pid;
  const fixtureHwnd = fixture0.hwnd;
  runPsDriver(['-Action', 'focus-window', '-Hwnd', String(fixtureHwnd)]);

  // 3. D1 + D3: Capture btnSave via CLI, annotate twice on btnSave (collision setup), test missing-room error path
  const capRes = runCli(['capture', '-Hwnd', String(fixtureHwnd), '-AutomationId', 'btnSave']);
  const targetSave = JSON.parse(capRes.stdout.trim());
  writeFileSync(targetSavePath, JSON.stringify(targetSave, null, 2));
  writeFileSync(join(ACCEPT_DIR, 'target-save.json'), JSON.stringify(targetSave, null, 2));

  const ann1 = JSON.parse(
    runCli([
      'annotate',
      '-Target',
      targetSavePath,
      '--text',
      'Save button contrast needs check',
      '--room',
      `${BASE}/s/${ROOM_ID}`,
    ]).stdout.trim(),
  );
  const ann2 = JSON.parse(
    runCli([
      'annotate',
      '-Target',
      targetSavePath,
      '--text',
      'Verify Save focus ring',
      '--room',
      `${BASE}/s/${ROOM_ID}`,
    ]).stdout.trim(),
  );
  const err4410 = runCli(
    ['annotate', '-Target', targetSavePath, '--text', 'Should fail', '--room', `${BASE}/s/missing1`],
    { expectFail: true },
  );

  // Give DO flush a moment and read HTTP GET /api/<room>
  const roomOpsAfterD3 = await waitFor(
    async () => {
      const r = await fetch(`${BASE}/api/${ROOM_ID}`);
      if (!r.ok) return null;
      const j = await r.json();
      return j.ops?.length === 2 ? j : null;
    },
    { timeoutMs: 8000, label: '2 ops in GET /api/<room>' },
  );
  writeFileSync(join(ACCEPT_DIR, 'room-ops-after-d3.json'), JSON.stringify(roomOpsAfterD3, null, 2));
  report.steps.d1_d3 = { ok: true, target: targetSave, ann1, ann2, missingRoomError: err4410.stderr.trim() };

  // 4. D4: Real Worker MCP readback
  const mcpAll = await mcpHttp(ROOM_ID, 'marklayer_list_annotations', {});
  const mcpDesktopOnly = await mcpHttp(ROOM_ID, 'marklayer_list_annotations', { desktop: true });
  const mcpWebOnly = await mcpHttp(ROOM_ID, 'marklayer_list_annotations', { desktop: false });
  const mcpDetail = await mcpHttp(ROOM_ID, 'marklayer_get_annotation', { id: ann1.opId });
  const mcpFeedback = await mcpHttp(ROOM_ID, 'marklayer_get_feedback', {});
  const mcpWebRoomFilter = await mcpHttp(WEB_ROOM_ID, 'marklayer_list_annotations', { desktop: false });
  if (
    mcpAll.annotations?.length !== 2 ||
    mcpDesktopOnly.annotations?.length !== 2 ||
    mcpWebOnly.annotations?.length !== 0
  ) {
    throw new Error(
      `Unexpected MCP list counts: all=${mcpAll.annotations?.length}, desktop=${mcpDesktopOnly.annotations?.length}, nonDesktop=${mcpWebOnly.annotations?.length}`,
    );
  }
  if (mcpDetail.desktopTarget?.automationId !== 'btnSave') {
    throw new Error(`MCP get_annotation missing btnSave desktopTarget: ${JSON.stringify(mcpDetail)}`);
  }
  if (mcpWebRoomFilter.annotations?.length !== 1) {
    throw new Error(
      `Web baseline room MCP desktop:false filter expected 1, got ${mcpWebRoomFilter.annotations?.length}`,
    );
  }
  writeFileSync(
    join(ACCEPT_DIR, 'mcp-readback.json'),
    JSON.stringify({ mcpAll, mcpDesktopOnly, mcpWebOnly, mcpDetail, mcpFeedback, mcpWebRoomFilter }, null, 2),
  );
  report.steps.d4 = {
    ok: true,
    allCount: mcpAll.annotations.length,
    desktopCount: mcpDesktopOnly.annotations.length,
    nonDesktopCount: mcpWebOnly.annotations.length,
    detailAutomationId: mcpDetail.desktopTarget.automationId,
  };

  // 5. D2: Real Chrome CDP Web Viewer readback (desktop room + web baseline room)
  chromeProc = spawn(
    CHROME_EXE,
    [
      '--headless=new',
      `--remote-debugging-port=${CDP_PORT}`,
      `--user-data-dir=${chromeDir}`,
      '--window-size=1280,900',
      '--no-first-run',
      '--no-default-browser-check',
    ],
    { stdio: 'ignore' },
  );
  const targets = await waitFor(
    async () => {
      const r = await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`);
      if (!r.ok) return null;
      const list = await r.json();
      return list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
    },
    { timeoutMs: 10000, label: 'Chrome CDP target' },
  );

  cdp = new CdpClient(targets.webSocketDebuggerUrl);
  await cdp.open();

  await cdp.send('Page.navigate', { url: `${BASE}/s/${WEB_ROOM_ID}` });
  const webText = await waitFor(
    async () => {
      const txt = await cdp.evaluate('document.body?.innerText || ""');
      return txt.includes('Web baseline note') ? txt : null;
    },
    { timeoutMs: 12000, label: 'Web baseline room render' },
  );

  await cdp.send('Page.navigate', { url: `${BASE}/s/${ROOM_ID}` });
  const deskViewerText = await waitFor(
    async () => {
      const txt = await cdp.evaluate('document.body?.innerText || ""');
      return txt.includes('Save button contrast needs check') ? txt : null;
    },
    { timeoutMs: 12000, label: 'Desktop room web viewer render' },
  );

  // Open Annotations panel and click first annotation row to display desktopTarget ContextSection
  await cdp.evaluate(`(() => {
    document.querySelector('[aria-label="Annotations panel"]')?.click();
    return true;
  })()`);
  await delay(400);
  await cdp.evaluate(`(() => {
    const btns = [...document.querySelectorAll('button')].filter(el => el.textContent?.includes('Save button contrast needs check'));
    const btn = btns[btns.length - 1];
    btn?.click();
    return Boolean(btn);
  })()`);
  await delay(500);
  const detailText = await cdp.evaluate('document.body?.innerText || ""');
  const shotDesktopWeb = await cdp.send('Page.captureScreenshot', { format: 'png' });
  writeFileSync(join(ACCEPT_DIR, 'web-readback.png'), Buffer.from(shotDesktopWeb.data, 'base64'));
  if (cdp.pageErrors.length > 0 || cdp.consoleErrors.length > 0) {
    throw new Error(
      `Web viewer errors: page=${JSON.stringify(cdp.pageErrors)} console=${JSON.stringify(cdp.consoleErrors)}`,
    );
  }
  if (!detailText.includes('btnSave') && !detailText.includes('ControlType.Button')) {
    throw new Error(
      `AnnotationDetail ContextSection missing desktopTarget info! detailText=${detailText.slice(0, 600)}`,
    );
  }
  report.steps.d2 = {
    ok: true,
    webBaselineOk: webText.includes('Web baseline note'),
    desktopCommentRendered:
      deskViewerText.includes('Save button contrast needs check') ||
      detailText.includes('Save button contrast needs check'),
    hasDesktopContext: true,
    pageErrors: cdp.pageErrors.length,
    consoleErrors: cdp.consoleErrors.length,
  };

  // 6. D5: Live Overlay with interactive bar docked right above fixture window (keeps cropped screenshots self-contained!)
  const barX = fixture0.windowRect.left;
  const barY = Math.max(12, fixture0.windowRect.top - 44);
  overlayProc = spawn(
    'node',
    [
      CLI,
      'overlay',
      '--room',
      `${BASE}/s/${ROOM_ID}`,
      '--interactive',
      '--state-out',
      overlayStatePath,
      '--bar-x',
      String(barX),
      '--bar-y',
      String(barY),
    ],
    { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] },
  );
  let overlayLog = '';
  overlayProc.stdout.on('data', (d) => {
    overlayLog += d.toString();
  });
  overlayProc.stderr.on('data', (d) => {
    overlayLog += d.toString();
  });

  const st2 = await waitFor(
    () => {
      if (overlayProc.exitCode !== null)
        throw new Error(`Overlay exited early (${overlayProc.exitCode}): ${overlayLog}`);
      const s = readJsonClean(overlayStatePath);
      return s.items?.length === 2 && s.items.every((i) => i.visible && i.boxRect && i.badgeRect) ? s : null;
    },
    { timeoutMs: 20000, label: 'overlay 2 visible items' },
  ).catch((err) => {
    const latest = (() => {
      try {
        return readFileSync(overlayStatePath, 'utf8');
      } catch {
        return '<missing>';
      }
    })();
    throw new Error(`${err.message}\n--- overlayLog ---\n${overlayLog}\n--- state ---\n${latest}`);
  });

  const overlayPid = st2.pid;
  if (rectsIntersect(st2.items[0].badgeRect, st2.items[1].badgeRect)) {
    throw new Error(
      `Badges overlap! b0=${JSON.stringify(st2.items[0].badgeRect)} b1=${JSON.stringify(st2.items[1].badgeRect)}`,
    );
  }
  const bDiff0 =
    Math.abs(st2.items[0].boxRect.left - fixture0.buttons.btnSave.left) +
    Math.abs(st2.items[0].boxRect.top - fixture0.buttons.btnSave.top);
  if (bDiff0 > 8) {
    throw new Error(
      `Box rect drift too high (${bDiff0}px): box=${JSON.stringify(st2.items[0].boxRect)} btn=${JSON.stringify(fixture0.buttons.btnSave)}`,
    );
  }

  // Cropped screenshot #1 (strictly fixture + overlay bar padding!)
  const shot1 = runPsDriver([
    '-Action',
    'crop-screenshot',
    '-X',
    String(Math.max(0, fixture0.windowRect.left - 24)),
    '-Y',
    String(Math.max(0, barY - 12)),
    '-Width',
    String(fixture0.windowRect.width + 48),
    '-Height',
    String(fixture0.windowRect.height + (fixture0.windowRect.top - barY) + 32),
    '-CapturePids',
    `${fixturePid},${overlayPid}`,
    '-OutPath',
    join(ACCEPT_DIR, 'overlay-two-badges.png'),
  ]);

  // Move fixture window (+100, +70) and measure overlay tracking!
  const moveStart = Date.now();
  runPsDriver(['-Action', 'move-window', '-Hwnd', String(fixtureHwnd), '-X', '280', '-Y', '210']);
  const fixtureMoved = await waitFor(
    () => {
      const f = readJsonClean(fixtureStatePath);
      return f.windowRect.left >= 270 ? f : null;
    },
    { timeoutMs: 3000, label: 'fixture moved state' },
  );

  const stMoved = await waitFor(
    () => {
      const s = readJsonClean(overlayStatePath);
      const b = s.items?.[0]?.boxRect;
      return b &&
        Math.abs(b.left - fixtureMoved.buttons.btnSave.left) <= 6 &&
        Math.abs(b.top - fixtureMoved.buttons.btnSave.top) <= 6
        ? s
        : null;
    },
    { timeoutMs: 3000, label: 'overlay tracked moved window' },
  );
  const trackLatencyMs = Date.now() - moveStart;

  // Cropped screenshot #2 at new moved bounds
  const shot2 = runPsDriver([
    '-Action',
    'crop-screenshot',
    '-X',
    String(Math.max(0, barX - 24)),
    '-Y',
    String(Math.max(0, barY - 12)),
    '-Width',
    String(fixtureMoved.windowRect.left - barX + fixtureMoved.windowRect.width + 48),
    '-Height',
    String(fixtureMoved.windowRect.top - barY + fixtureMoved.windowRect.height + 32),
    '-CapturePids',
    `${fixturePid},${overlayPid}`,
    '-OutPath',
    join(ACCEPT_DIR, 'overlay-moved.png'),
  ]);

  // Click passthrough check: click center of btnSave (inside BOTH red box forms!), strictly allowing ONLY fixturePid
  runPsDriver(['-Action', 'focus-window', '-Hwnd', String(fixtureHwnd)]);
  const saveCx = Math.round(fixtureMoved.buttons.btnSave.left + fixtureMoved.buttons.btnSave.width / 2);
  const saveCy = Math.round(fixtureMoved.buttons.btnSave.top + fixtureMoved.buttons.btnSave.height / 2);
  const clickRes = runPsDriver([
    '-Action',
    'click',
    '-X',
    String(saveCx),
    '-Y',
    String(saveCy),
    '-AllowedPids',
    String(fixturePid),
  ]);
  const fixtureAfterClick = await waitFor(
    () => {
      const f = readJsonClean(fixtureStatePath);
      return f.saveClicks === 1 ? f : null;
    },
    { timeoutMs: 3000, label: 'btnSave click passthrough incremented saveClicks' },
  );
  if (clickRes.afterForegroundPid === overlayPid) {
    throw new Error(`Overlay unexpectedly stole foreground on passthrough click! after=${clickRes.afterForegroundPid}`);
  }

  report.steps.d5 = {
    ok: true,
    screenshotModes: [shot1.mode, shot2.mode],
    initialBoxVsButtonDiffPx: bDiff0,
    badgesDisjoint: !rectsIntersect(st2.items[0].badgeRect, st2.items[1].badgeRect),
    badge0: st2.items[0].badgeRect,
    badge1: st2.items[1].badgeRect,
    trackLatencyMs,
    movedBoxRect: stMoved.items[0].boxRect,
    clickPassthrough: {
      inputMode: clickRes.inputMode,
      hardwareCursorMoved: clickRes.hardwareCursorMoved,
      saveClicks: fixtureAfterClick.saveClicks,
      targetOwnerPid: clickRes.targetOwner.pid,
      afterForegroundPid: clickRes.afterForegroundPid,
    },
  };

  // 7. D6: Real interactive human-like flow (+ Annotate -> drag across btnCancel -> type comment -> Enter -> room sync)
  const annBtn = stMoved.annotateRect;
  const annCx = Math.round(annBtn.left + annBtn.width / 2);
  const annCy = Math.round(annBtn.top + annBtn.height / 2);
  runPsDriver(['-Action', 'click', '-X', String(annCx), '-Y', String(annCy), '-AllowedPids', String(overlayPid)]);

  // Wait until CaptureCurtain covers btnCancel (WindowFromPoint hits overlayPid)
  const cancelBtn = fixtureMoved.buttons.btnCancel;
  const cancelCx = Math.round(cancelBtn.left + cancelBtn.width / 2);
  const cancelCy = Math.round(cancelBtn.top + cancelBtn.height / 2);
  await waitFor(
    () => {
      const owner = runPsDriver(['-Action', 'inspect-point', '-X', String(cancelCx), '-Y', String(cancelCy)]);
      return owner.pid === overlayPid ? owner : null;
    },
    { timeoutMs: 4000, label: 'CaptureCurtain active over btnCancel' },
  );

  const dragRes = runPsDriver([
    '-Action',
    'drag',
    '-X1',
    String(cancelBtn.left + 12),
    '-Y1',
    String(cancelBtn.top + 10),
    '-X2',
    String(cancelBtn.left + cancelBtn.width - 12),
    '-Y2',
    String(cancelBtn.top + cancelBtn.height - 10),
    '-AllowedPids',
    String(overlayPid),
  ]);

  const typeRes = runPsDriver([
    '-Action',
    'type-submit',
    '-Text',
    'Interactive Cancel note',
    '-AllowedPids',
    String(overlayPid),
  ]);

  const st3 = await waitFor(
    () => {
      const s = readJsonClean(overlayStatePath);
      return s.items?.length === 3 && s.items[2].visible ? s : null;
    },
    { timeoutMs: 10000, label: '3rd interactive annotation rendered on overlay' },
  );

  const roomOpsAfterD6 = await waitFor(
    async () => {
      const r = await fetch(`${BASE}/api/${ROOM_ID}`);
      if (!r.ok) return null;
      const j = await r.json();
      return j.ops?.length === 3 ? j : null;
    },
    { timeoutMs: 8000, label: '3 ops persisted in room after D6' },
  );

  const mcpAfterD6 = await mcpHttp(ROOM_ID, 'marklayer_list_annotations', { desktop: true });
  if (mcpAfterD6.annotations?.length !== 3) {
    throw new Error(`Expected 3 MCP desktop annotations after D6, got ${mcpAfterD6.annotations?.length}`);
  }

  const shot3 = runPsDriver([
    '-Action',
    'crop-screenshot',
    '-X',
    String(Math.max(0, barX - 24)),
    '-Y',
    String(Math.max(0, barY - 12)),
    '-Width',
    String(fixtureMoved.windowRect.left - barX + fixtureMoved.windowRect.width + 48),
    '-Height',
    String(fixtureMoved.windowRect.top - barY + fixtureMoved.windowRect.height + 32),
    '-CapturePids',
    `${fixturePid},${overlayPid}`,
    '-OutPath',
    join(ACCEPT_DIR, 'overlay-d6-created.png'),
  ]);

  writeFileSync(join(ACCEPT_DIR, 'room-ops-after-d6.json'), JSON.stringify(roomOpsAfterD6, null, 2));
  const fixtureFinal = readJsonClean(fixtureStatePath);
  if (fixtureFinal.cancelClicks !== 0) {
    throw new Error(`CaptureCurtain leaked drag click to btnCancel (cancelClicks=${fixtureFinal.cancelClicks})`);
  }

  report.steps.d6 = {
    ok: true,
    screenshotMode: shot3.mode,
    dragRes,
    typeRes,
    overlayCount: st3.items.length,
    thirdOpText: roomOpsAfterD6.ops[2]?.text,
    thirdOpAutomationId: roomOpsAfterD6.ops[2]?.desktopTarget?.automationId,
    thirdOpRelativeRect: roomOpsAfterD6.ops[2]?.desktopTarget?.relativeRect,
    mcpCountAfterD6: mcpAfterD6.annotations.length,
    cancelClicksDuringCurtainDrag: fixtureFinal.cancelClicks,
  };

  // 8. Real Worker Password-Protected Room (4401 + HTTP 401 + Bearer unlock for CLI & MCP)
  const seedPwdRoom = await fetch(`${BASE}/api/${PWD_ROOM_ID}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ ops: [], width: 1280 }),
  });
  if (!seedPwdRoom.ok) throw new Error(`Password room seed failed (${seedPwdRoom.status})`);

  const hashRes = spawnSync(
    'bun',
    [
      '-e',
      `import { hashPassword } from './apps/worker/src/lock/password.ts'; console.log(await hashPassword('${PWD_SECRET}'));`,
    ],
    { cwd: ROOT, encoding: 'utf8' },
  );
  if (hashRes.status !== 0) throw new Error(`hashPassword failed: ${hashRes.stderr || hashRes.stdout}`);
  const pwdHash = hashRes.stdout.trim();

  const d1LockRes = spawnSync(
    process.execPath,
    [
      join(ROOT, 'node_modules', 'wrangler', 'bin', 'wrangler.js'),
      'd1',
      'execute',
      'marklayer',
      '--local',
      '--persist-to',
      wranglerStateDir,
      '--command',
      `UPDATE annotations SET password_hash = '${pwdHash}', password_gen = 1 WHERE id = '${PWD_ROOM_ID}';`,
    ],
    { cwd: join(ROOT, 'apps', 'worker'), encoding: 'utf8' },
  );
  if (d1LockRes.status !== 0) throw new Error(`D1 lock update failed: ${d1LockRes.stderr || d1LockRes.stdout}`);

  const noPwdCli = runCli(
    ['annotate', '-Target', targetSavePath, '--text', 'No pwd fail', '--room', `${BASE}/s/${PWD_ROOM_ID}`],
    {
      expectFail: true,
    },
  );
  const wrongPwdCli = runCli(
    [
      'annotate',
      '-Target',
      targetSavePath,
      '--text',
      'Wrong pwd fail',
      '--room',
      `${BASE}/s/${PWD_ROOM_ID}`,
      '--password',
      'wrong-secret',
    ],
    { expectFail: true },
  );
  const okPwdCli = JSON.parse(
    runCli([
      'annotate',
      '-Target',
      targetSavePath,
      '--text',
      'Locked room annotation',
      '--room',
      `${BASE}/s/${PWD_ROOM_ID}`,
      '--password',
      PWD_SECRET,
    ]).stdout.trim(),
  );

  const unauthMcp = await fetch(`${BASE}/s/${PWD_ROOM_ID}/mcp?agent=accept-agent`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: 'marklayer_list_annotations', arguments: {} },
    }),
  });
  if (unauthMcp.status !== 401) {
    throw new Error(`Expected 401 for unauthenticated password-room MCP call, got ${unauthMcp.status}`);
  }
  const authMcp = await mcpHttp(
    PWD_ROOM_ID,
    'marklayer_list_annotations',
    { desktop: true },
    { Authorization: `Bearer ${PWD_SECRET}` },
  );
  if (authMcp.annotations?.length !== 1 || authMcp.annotations[0].text !== 'Locked room annotation') {
    throw new Error(`Expected 1 unlocked MCP annotation, got ${JSON.stringify(authMcp)}`);
  }

  const pwdEvidence = {
    roomId: PWD_ROOM_ID,
    missingPasswordError: noPwdCli.stderr.trim(),
    wrongPasswordError: wrongPwdCli.stderr.trim(),
    unlockedCliWrite: okPwdCli,
    unauthenticatedMcpStatus: unauthMcp.status,
    authenticatedMcpReadback: authMcp,
  };
  writeFileSync(join(ACCEPT_DIR, 'password-room-4401.json'), JSON.stringify(pwdEvidence, null, 2));
  report.steps.passwordRoom4401 = {
    ok: true,
    missingPasswordError: pwdEvidence.missingPasswordError,
    wrongPasswordError: pwdEvidence.wrongPasswordError,
    cliOpId: okPwdCli.opId,
    unauthenticatedMcpStatus: unauthMcp.status,
    authenticatedMcpCount: authMcp.annotations.length,
  };

  report.ok = true;
} finally {
  cdp?.close();
  killTree(overlayProc?.pid);
  killTree(fixtureProc?.pid);
  killTree(chromeProc?.pid);
  killTree(workerProc?.pid);
  rmSync(workDir, { recursive: true, force: true });
}

writeFileSync(join(ACCEPT_DIR, 'desktop-acceptance.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ ok: report.ok, roomId: ROOM_ID, steps: Object.keys(report.steps) }, null, 2));
