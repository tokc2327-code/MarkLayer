import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';

const adapterScript = fileURLToPath(new URL('./adapter.ps1', import.meta.url));
const overlayScript = fileURLToPath(new URL('./overlay.ps1', import.meta.url));
const [command, ...args] = process.argv.slice(2);

function option(name) {
  const i = args.indexOf(name);
  return i < 0 ? undefined : args[i + 1];
}

function hasFlag(name) {
  return args.includes(name);
}

function getRoomPassword() {
  // biome-ignore lint/suspicious/noUndeclaredEnvVars: CLI runtime credential passed outside Turborepo cache
  return option('--password') ?? process.env.MARKLAYER_PASSWORD;
}

function validateDesktopTarget(target) {
  const stringKeys = ['app', 'windowTitle', 'controlType', 'name', 'automationId'];
  const rectKeys = ['left', 'top', 'width', 'height'];
  const rectValid = (r) => r && rectKeys.every((k) => Number.isFinite(r[k])) && r.width > 0 && r.height > 0;
  if (
    target?.kind !== 'windows-uia' ||
    !stringKeys.every((k) => typeof target[k] === 'string') ||
    !Array.isArray(target.ancestry) ||
    !target.ancestry.every((a) => ['controlType', 'name', 'automationId'].every((k) => typeof a[k] === 'string')) ||
    !rectValid(target.relativeRect) ||
    !rectValid(target.captured) ||
    !Number.isFinite(target.captured.dpr) ||
    target.captured.dpr <= 0 ||
    !target.screen ||
    !['width', 'height', 'scale'].every((k) => Number.isFinite(target.screen[k]) && target.screen[k] > 0)
  ) {
    throw new Error('Invalid desktop target');
  }
}

function resolveRoomSocket(room, id, password) {
  const base = new URL(room.includes('://') ? room : `https://marklayer.app/s/${encodeURIComponent(room)}`);
  if (!['http:', 'https:'].includes(base.protocol)) throw new Error('Invalid room URL');
  const roomId = base.pathname.match(/^\/s\/([^/]+)/)?.[1];
  if (!roomId) throw new Error('Room URL must contain /s/<id>');
  const wsUrl = new URL(`/ws/${roomId}`, base);
  wsUrl.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:';
  wsUrl.search = new URLSearchParams({ peerId: id, uid: id, name: 'Desktop CLI', color: '#ef4444' }).toString();
  const headers = password ? { Authorization: `Bearer ${password}` } : {};
  return { roomId, wsUrl, headers };
}

function openRoomSocket({ room, password, name = 'Desktop CLI' }) {
  const id = randomUUID();
  const { roomId, wsUrl, headers } = resolveRoomSocket(room, id, password);
  wsUrl.search = new URLSearchParams({ peerId: id, uid: id, name, color: '#ef4444' }).toString();
  const ws = new WebSocket(wsUrl, { headers });
  return { id, roomId, ws };
}

function closeMessage(code, password) {
  if (code === 4401) {
    return password
      ? 'Room rejected the password'
      : 'Room is password-protected; pass --password or set MARKLAYER_PASSWORD';
  }
  if (code === 4410) return 'Room has expired or does not exist';
  return `Room closed before acknowledgement (code ${code})`;
}

async function atomicWriteJson(filePath, data) {
  const tmp = `${filePath}.tmp`;
  await writeFile(tmp, JSON.stringify(data, null, 2), 'utf8');
  await rename(tmp, filePath);
}

function projectOverlayItems(ops) {
  const repliesByParent = new Map();
  for (const op of ops) {
    if (op?.tool === 'comment' && op.parentId) {
      const arr = repliesByParent.get(op.parentId) ?? [];
      arr.push(op);
      repliesByParent.set(op.parentId, arr);
    }
  }
  return ops
    .filter((op) => op?.tool === 'comment' && !op.parentId && op.desktopTarget?.kind === 'windows-uia')
    .map((op) => ({
      id: op.id,
      num: op.num,
      text: op.text,
      status: op.status ?? (op.resolved ? 'resolved' : 'open'),
      color: op.color ?? '#ef4444',
      desktopTarget: op.desktopTarget,
      replies: repliesByParent.get(op.id) ?? [],
    }));
}

if (command === 'annotate') {
  try {
    const targetPath = option('-Target');
    const text = option('--text');
    const room = option('--room');
    const password = getRoomPassword();
    const author = option('--author') ?? 'Desktop CLI';
    if (!targetPath || !text || !room) throw new Error('annotate requires -Target, --text and --room');
    const target = JSON.parse(await readFile(targetPath, 'utf8'));
    validateDesktopTarget(target);
    const { id, roomId, ws } = openRoomSocket({ room, password, name: author });
    let timer;
    const result = await new Promise((resolve, reject) => {
      let sentNum = 1;
      timer = setTimeout(() => reject(new Error('Room response timed out')), 10000);
      ws.on('error', (err) => reject(new Error(`Room connection failed: ${err.message}`)));
      ws.on('close', (code) => reject(new Error(closeMessage(code, password))));
      ws.on('message', (raw) => {
        const msg = JSON.parse(raw.toString());
        if (msg.type === 'init') {
          if (msg.canEdit === false) return reject(new Error('Room is read-only'));
          sentNum = 1 + (msg.ops ?? []).filter((o) => o.tool === 'comment' && !o.parentId).length;
          ws.send(
            JSON.stringify({
              type: 'op',
              clientOpId: id,
              op: {
                id,
                tool: 'comment',
                num: sentNum,
                text,
                author,
                x: 0,
                y: 0,
                color: '#ef4444',
                lineWidth: 2,
                ts: Date.now(),
                desktopTarget: target,
              },
            }),
          );
        } else if (msg.opId === id && msg.type === 'ack') {
          clearTimeout(timer);
          resolve({ receipt: msg, num: sentNum });
        } else if (msg.opId === id && msg.type === 'nack') {
          clearTimeout(timer);
          reject(new Error(msg.reason ?? msg.code ?? 'Room refused write'));
        }
      });
    }).finally(() => {
      clearTimeout(timer);
      ws.close();
    });
    console.log(JSON.stringify({ opId: id, roomId, num: result.num, receipt: result.receipt }));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
} else if (command === 'overlay') {
  const room = option('--room');
  const targetsPath = option('-Targets') ?? option('--targets');
  const password = getRoomPassword();
  const interactive = hasFlag('--interactive');
  const stateOut = option('--state-out');
  const barX = option('--bar-x');
  const barY = option('--bar-y');
  const author = option('--author') ?? 'Desktop Reviewer';

  if (!room && !targetsPath) {
    console.error('overlay requires --room <id-or-url> or --targets <json>');
    process.exitCode = 1;
  } else if (!room && targetsPath) {
    const psArgs = [
      '-NoProfile',
      '-STA',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      overlayScript,
      '-Targets',
      targetsPath,
    ];
    if (interactive) psArgs.push('-Interactive');
    if (stateOut) psArgs.push('-StateOut', stateOut);
    if (barX !== undefined) psArgs.push('-BarX', barX);
    if (barY !== undefined) psArgs.push('-BarY', barY);
    const result = spawnSync('powershell.exe', psArgs, { stdio: 'inherit' });
    process.exitCode = result.status ?? 1;
  } else {
    const workDir = await mkdtemp(join(tmpdir(), 'marklayer-desktop-overlay-'));
    const stateFile = join(workDir, 'targets.json');
    const outboxDir = join(workDir, 'outbox');
    await atomicWriteJson(stateFile, []);
    let ops = [];
    let psProc = null;
    let pollTimer = null;
    let ws = null;
    const pendingOps = new Map();

    const cleanup = async () => {
      if (pollTimer) clearInterval(pollTimer);
      if (psProc && psProc.exitCode === null) psProc.kill();
      try {
        ws?.close();
      } catch {}
      await rm(workDir, { recursive: true, force: true }).catch(() => {});
    };

    try {
      const sock = openRoomSocket({ room, password, name: author });
      ws = sock.ws;

      await new Promise((resolve, reject) => {
        const initTimer = setTimeout(() => reject(new Error('Room init timed out')), 10000);
        ws.on('error', (err) => {
          clearTimeout(initTimer);
          reject(new Error(`Room connection failed: ${err.message}`));
        });
        ws.on('close', (code) => {
          clearTimeout(initTimer);
          reject(new Error(closeMessage(code, password)));
        });
        ws.on('message', async (raw) => {
          const msg = JSON.parse(raw.toString());
          if (msg.type === 'init') {
            clearTimeout(initTimer);
            ops = Array.isArray(msg.ops) ? msg.ops : [];
            await atomicWriteJson(stateFile, projectOverlayItems(ops));
            resolve();
          } else if (msg.type === 'op' && msg.op) {
            if (!ops.some((o) => o.id === msg.op.id)) ops.push(msg.op);
            await atomicWriteJson(stateFile, projectOverlayItems(ops));
          } else if (msg.type === 'update_op' && msg.opId && msg.patch) {
            ops = ops.map((o) => (o.id === msg.opId ? { ...o, ...msg.patch } : o));
            await atomicWriteJson(stateFile, projectOverlayItems(ops));
          } else if (msg.type === 'undo' && msg.opId) {
            ops = ops.filter((o) => o.id !== msg.opId);
            await atomicWriteJson(stateFile, projectOverlayItems(ops));
          } else if (msg.type === 'clear') {
            ops = [];
            await atomicWriteJson(stateFile, []);
          } else if (msg.type === 'ack' && msg.opId && pendingOps.has(msg.opId)) {
            const pending = pendingOps.get(msg.opId);
            pendingOps.delete(msg.opId);
            if (!ops.some((o) => o.id === pending.op.id)) ops.push(pending.op);
            await atomicWriteJson(stateFile, projectOverlayItems(ops));
            pending.resolve(msg);
          } else if (msg.type === 'nack' && msg.opId && pendingOps.has(msg.opId)) {
            const pending = pendingOps.get(msg.opId);
            pendingOps.delete(msg.opId);
            pending.reject(new Error(msg.reason ?? msg.code ?? 'Room refused write'));
          }
        });
      });

      const psArgs = [
        '-NoProfile',
        '-STA',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        overlayScript,
        '-Targets',
        stateFile,
      ];
      if (interactive) psArgs.push('-Interactive', '-OutboxDir', outboxDir);
      if (stateOut) psArgs.push('-StateOut', stateOut);
      if (barX !== undefined) psArgs.push('-BarX', barX);
      if (barY !== undefined) psArgs.push('-BarY', barY);

      psProc = spawn('powershell.exe', psArgs, { stdio: 'inherit' });

      const sendOutboxOp = (op) =>
        new Promise((resolve, reject) => {
          pendingOps.set(op.id, { op, resolve, reject });
          ws.send(JSON.stringify({ type: 'op', clientOpId: op.id, op }));
          setTimeout(() => {
            if (pendingOps.has(op.id)) {
              pendingOps.delete(op.id);
              reject(new Error('Room write timed out'));
            }
          }, 10000);
        });

      let flushing = false;
      pollTimer = setInterval(async () => {
        if (!interactive || flushing || ws.readyState !== WebSocket.OPEN) return;
        flushing = true;
        try {
          const files = await readdir(outboxDir).catch(() => []);
          for (const file of files.filter((f) => f.endsWith('.json')).sort()) {
            const fullPath = join(outboxDir, file);
            try {
              const req = JSON.parse((await readFile(fullPath, 'utf8')).replace(/^\uFEFF/, ''));
              const id = randomUUID();
              if (req.type === 'create' && req.desktopTarget && req.text) {
                validateDesktopTarget(req.desktopTarget);
                const num = 1 + ops.filter((o) => o.tool === 'comment' && !o.parentId).length;
                await sendOutboxOp({
                  id,
                  tool: 'comment',
                  num,
                  text: req.text,
                  author,
                  x: 0,
                  y: 0,
                  color: '#ef4444',
                  lineWidth: 2,
                  ts: Date.now(),
                  desktopTarget: req.desktopTarget,
                });
              } else if (req.type === 'reply' && req.parentId && req.text) {
                await sendOutboxOp({
                  id,
                  tool: 'comment',
                  num: 0,
                  parentId: req.parentId,
                  text: req.text,
                  author,
                  x: 0,
                  y: 0,
                  color: '#ef4444',
                  lineWidth: 2,
                  ts: Date.now(),
                });
              }
            } catch (err) {
              console.error(`Overlay outbox item failed: ${err.message}`);
            } finally {
              await rm(fullPath, { force: true }).catch(() => {});
            }
          }
        } finally {
          flushing = false;
        }
      }, 60);

      process.on('SIGINT', async () => {
        await cleanup();
        process.exit(0);
      });
      process.on('SIGTERM', async () => {
        await cleanup();
        process.exit(0);
      });

      const exitCode = await new Promise((resolve) => psProc.on('close', resolve));
      await cleanup();
      process.exitCode = exitCode ?? 0;
    } catch (error) {
      await cleanup();
      console.error(error.message);
      process.exitCode = 1;
    }
  }
} else if (['list-windows', 'snapshot', 'resolve', 'capture'].includes(command)) {
  const result = spawnSync(
    'powershell.exe',
    ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', adapterScript, '-Command', command, ...args],
    { stdio: 'inherit' },
  );
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} else {
  console.error(
    'Usage: node cli.mjs list-windows | snapshot -Hwnd <handle> | capture (-Hwnd <h> | -X <px> -Y <px>) | resolve -Target <json> | annotate -Target <json> --text <text> --room <id-or-url> [--password <pwd>] | overlay (--room <id-or-url> [--interactive] | --targets <json>)',
  );
  process.exitCode = 1;
}
