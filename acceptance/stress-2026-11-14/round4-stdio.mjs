import { spawn } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';

const { room } = JSON.parse(await readFile(new URL('./round4-semantics.json', import.meta.url), 'utf8'));
const child = spawn(process.execPath, ['apps/mcp/dist/cli.js', '--api-base', 'http://127.0.0.1:5397', '--room', room]);
const lines = createInterface({ input: child.stdout });
const pending = new Map();
const records = [];
let id = 0;
lines.on('line', (line) => {
  try {
    const msg = JSON.parse(line);
    if (pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  } catch {}
});
const req = (method, params) =>
  new Promise((resolve, reject) => {
    const n = ++id;
    const timer = setTimeout(() => reject(Error(`timeout ${method}`)), 15000);
    pending.set(n, (msg) => {
      clearTimeout(timer);
      records.push(msg);
      resolve(msg);
    });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: n, method, params }) + '\n');
  });
try {
  await req('initialize', {
    protocolVersion: '2025-03-26',
    capabilities: {},
    clientInfo: { name: 'stdio-probe', version: '1' },
  });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  await req('tools/list', {});
  const q = await req('tools/call', { name: 'marklayer_query_semantics', arguments: { page: 'https://example.com/' } });
  const version = JSON.parse(q.result.content[0].text).roomVersion;
  await req('tools/call', {
    name: 'marklayer_register_semantic',
    arguments: {
      name: 'stdio-button',
      page: 'https://example.com/',
      selector: '#stdio',
      description: 'stdio probe',
      version,
    },
  });
  await req('tools/call', { name: 'marklayer_query_semantics', arguments: { name: 'stdio-button' } });
  await writeFile(new URL('./round4-stdio.json', import.meta.url), JSON.stringify({ room, records }, null, 2));
  console.log(JSON.stringify(records.slice(-3)));
} finally {
  child.kill();
}
