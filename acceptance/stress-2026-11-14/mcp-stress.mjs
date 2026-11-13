import { randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';

const base = process.env.STRESS_BASE ?? 'http://127.0.0.1:5199';
const room = `stress-${randomUUID()}`;
const records = [];
const endpoint = `${base}/s/${room}/mcp`;
const seed = await fetch(`${base}/api/${room}`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ ops: [], url: 'https://example.com', width: 1440 }),
});
if (!seed.ok) throw new Error(`seed: ${seed.status} ${await seed.text()}`);
async function request(client, method, params) {
  const start = performance.now();
  try {
    const response = await fetch(`${endpoint}?agent=stress-${client}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
        ...(sessions[client] ? { 'mcp-session-id': sessions[client] } : {}),
      },
      body: JSON.stringify({ jsonrpc: '2.0', id: randomUUID(), method, params }),
    });
    const text = await response.text();
    const line = text.split('\n').find((s) => s.startsWith('data: '));
    const body = line ? JSON.parse(line.slice(6)) : JSON.parse(text);
    if (response.headers.get('mcp-session-id')) sessions[client] = response.headers.get('mcp-session-id');
    records.push({ client, method, params, ms: performance.now() - start, status: response.status, body });
    return body;
  } catch (error) {
    records.push({ client, method, params, ms: performance.now() - start, error: String(error) });
    return {};
  }
}
const sessions = Array(4).fill(null);
const call = (client, name, args = {}) => request(client, 'tools/call', { name, arguments: args });
const decode = (result) => {
  try {
    return JSON.parse(result?.result?.content?.[0]?.text);
  } catch {
    return null;
  }
};
await Promise.all(
  sessions.map((_, i) =>
    request(i, 'initialize', {
      protocolVersion: '2025-03-26',
      capabilities: {},
      clientInfo: { name: `stress-${i}`, version: '1' },
    }),
  ),
);
const created = await Promise.all(
  sessions.map((_, i) =>
    call(i, 'marklayer_create_annotation', { text: `stress-annotation-${i}`, x: 100 + i * 30, y: 100 }),
  ),
);
const ids = created.map((x) => decode(x)?.id).filter(Boolean);
await Promise.all(
  sessions.flatMap((_, i) => [
    call(i, 'marklayer_read_page'),
    call(i, 'marklayer_list_annotations'),
    ...ids.flatMap((id, j) => [
      call(i, 'marklayer_reply', { id, text: `stress-reply-${i}-${j}` }),
      call(i, 'marklayer_get_annotation', { id }),
    ]),
  ]),
);
await Promise.all(ids.map((id, i) => call(i, 'marklayer_get_annotation', { id })));
const snapshot = await fetch(`${base}/api/${room}`).then((r) => r.text());
await writeFile(new URL('./mcp-raw.json', import.meta.url), JSON.stringify({ room, ids, records, snapshot }, null, 2));
console.log(
  JSON.stringify({
    room,
    ids,
    count: records.length,
    failures: records.filter((r) => r.error || r.status !== 200 || r.body?.error || r.body?.result?.isError).length,
  }),
);
