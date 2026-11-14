import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./adapter.ps1', import.meta.url));
const [command, ...args] = process.argv.slice(2);
if (command === 'annotate') {
  try {
    const option = (name) => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
    const targetPath = option('-Target');
    const text = option('--text');
    const room = option('--room');
    if (!targetPath || !text || !room) throw new Error('annotate requires -Target, --text and --room');
    const target = JSON.parse(await readFile(targetPath, 'utf8'));
    const stringKeys = ['app', 'windowTitle', 'controlType', 'name', 'automationId'];
    const rectKeys = ['left', 'top', 'width', 'height'];
    const rectValid = (r) => r && rectKeys.every((k) => Number.isFinite(r[k])) && r.width > 0 && r.height > 0;
    if (target.kind !== 'windows-uia' || !stringKeys.every((k) => typeof target[k] === 'string') ||
        !Array.isArray(target.ancestry) || !target.ancestry.every((a) => ['controlType', 'name', 'automationId'].every((k) => typeof a[k] === 'string')) ||
        !rectValid(target.relativeRect) || !rectValid(target.captured) || !Number.isFinite(target.captured.dpr) ||
        !target.screen || !['width', 'height', 'scale'].every((k) => Number.isFinite(target.screen[k]) && target.screen[k] > 0)) throw new Error('Invalid desktop target');
    const base = new URL(room.includes('://') ? room : `https://marklayer.app/s/${encodeURIComponent(room)}`);
    if (!['http:', 'https:'].includes(base.protocol)) throw new Error('Invalid room URL');
    const roomId = base.pathname.match(/^\/s\/([^/]+)/)?.[1];
    if (!roomId) throw new Error('Room URL must contain /s/<id>');
    const id = randomUUID();
    const wsUrl = new URL(`/ws/${roomId}`, base);
    wsUrl.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:';
    wsUrl.search = new URLSearchParams({ peerId: id, uid: id, name: 'Desktop CLI', color: '#ff0000' });
    const ws = new WebSocket(wsUrl);
    let timer;
    const result = await new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('Room response timed out')), 10000);
      ws.onerror = () => reject(new Error('Room connection failed'));
      ws.onclose = () => reject(new Error('Room closed before acknowledgement'));
      ws.onmessage = (event) => {
        const msg = JSON.parse(event.data);
        if (msg.type === 'init') {
          if (msg.canEdit === false) return reject(new Error('Room is read-only'));
          const num = 1 + (msg.ops ?? []).filter((o) => o.tool === 'comment' && !o.parentId).length;
          ws.send(JSON.stringify({ type: 'op', clientOpId: id, op: { id, tool: 'comment', num, text, x: 0, y: 0, color: '#ff0000', lineWidth: 2, ts: Date.now(), desktopTarget: target } }));
        } else if (msg.opId === id && msg.type === 'ack') { clearTimeout(timer); resolve(msg); }
        else if (msg.opId === id && msg.type === 'nack') { clearTimeout(timer); reject(new Error(msg.reason ?? msg.code ?? 'Room refused write')); }
      };
    }).finally(() => { clearTimeout(timer); ws.close(); });
    console.log(JSON.stringify({ opId: id, receipt: result }));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
} else if (['list-windows', 'snapshot', 'resolve'].includes(command)) {
  const result = spawnSync('powershell.exe', ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', script, '-Command', command, ...args], { stdio: 'inherit' });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} else {
  console.error('Usage: node cli.mjs list-windows | snapshot -Hwnd <handle> | resolve -Target <json> | annotate -Target <json> --text <text> --room <id-or-url>');
  process.exitCode = 1;
}
