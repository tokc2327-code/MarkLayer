import { readFile, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';

const d = JSON.parse(await readFile(new URL('./round4-offline-raw.json', import.meta.url), 'utf8'));
const checks = (name) => d.checks.filter((x) => x.stage === name);
const frames = d.events
  .filter((x) => ['Network.webSocketFrameSent', 'Network.webSocketFrameReceived'].includes(x.method))
  .flatMap((x) => {
    try {
      return [
        {
          client: x.client,
          direction: x.method,
          timestamp: x.params.timestamp,
          message: JSON.parse(x.params.response.payloadData),
        },
      ];
    } catch {
      return [];
    }
  });
const sent = frames.filter((x) => x.direction.endsWith('Sent') && x.message.clientOpId);
const receipts = sent.map((s) => {
  const r = frames.find(
    (x) =>
      x.client === s.client &&
      x.direction.endsWith('Received') &&
      ['ack', 'nack'].includes(x.message.type) &&
      x.message.opId === s.message.clientOpId,
  );
  return {
    client: s.client,
    id: s.message.clientOpId,
    type: s.message.type,
    sentTimestamp: s.timestamp,
    receivedTimestamp: r?.timestamp ?? null,
    latencyMs: r ? Math.round((r.timestamp - s.timestamp) * 100000) / 100 : null,
    receipt: r?.message ?? null,
  };
});
const dist = (entries) => {
  const a = entries
    .filter((x) => x.receipt?.type === 'ack')
    .map((x) => x.latencyMs)
    .sort((a, b) => a - b);
  return {
    n: a.length,
    p50: a[Math.ceil(a.length * 0.5) - 1] ?? null,
    p95: a[Math.ceil(a.length * 0.95) - 1] ?? null,
    max: a.at(-1) ?? null,
  };
};
const server = checks('server-a')[0]?.body?.ops ?? [];
const sort = (x) => [...x].sort((a, b) => a.id.localeCompare(b.id));
const clients = checks('final-room-a').map((x) => ({
  client: x.client,
  count: x.ops.length,
  identical: isDeepStrictEqual(sort(x.ops), sort(server)),
  missing: server.filter((op) => !x.ops.some((a) => a.id === op.id)).map((op) => op.id),
  extra: x.ops.filter((op) => !server.some((a) => a.id === op.id)).map((op) => op.id),
}));
const ids = checks('offline-peer-write-attempt')[0]?.ids ?? [];
const offlineReceipts = receipts.filter(
  (r) =>
    r.client === 2 &&
    frames.some((f) => f.client === 2 && f.message.clientOpId === r.id && ids.includes(f.message.op?.id)),
);
const recoveredIds = checks('recovered-writes')[0]?.ids ?? [];
const recoveredReceipts = receipts.filter(
  (r) =>
    r.client === 0 &&
    frames.some((f) => f.client === 0 && f.message.clientOpId === r.id && recoveredIds.includes(f.message.op?.id)),
);
const summary = {
  recoveredWrites: dist(recoveredReceipts),
  recoveredWritesSent: recoveredReceipts.length,
  recoveredIds,
  error: d.error ?? null,
  offlineMs: (checks('offline-end')[0]?.at ?? 0) - (checks('offline-start')[0]?.at ?? 0),
  sent: sent.length,
  receipts,
  all: dist(receipts),
  offlineWrites: dist(offlineReceipts),
  offlineWritesSent: offlineReceipts.length,
  missingReceipts: receipts.filter((x) => !x.receipt).length,
  offlineIds: ids,
  serverCount: server.length,
  clients,
};
await writeFile(new URL('./round4-offline-summary.json', import.meta.url), JSON.stringify(summary, null, 2));
console.log(JSON.stringify(summary, null, 2));
