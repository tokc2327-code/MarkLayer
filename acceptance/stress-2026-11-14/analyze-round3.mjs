import { readFile, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';

const d = JSON.parse(await readFile(new URL('./round3-raw.json', import.meta.url), 'utf8'));
const frames = d.events
  .filter((e) => ['Network.webSocketFrameSent', 'Network.webSocketFrameReceived'].includes(e.method))
  .flatMap((e) => {
    try {
      return [
        {
          client: e.client,
          method: e.method,
          at: e.at,
          timestamp: e.params.timestamp,
          payload: e.params.response.payloadData,
          msg: JSON.parse(e.params.response.payloadData),
        },
      ];
    } catch {
      return [];
    }
  });
const sent = frames.filter((x) => x.method.endsWith('Sent') && x.msg.clientOpId);
const receipts = sent.map((s) => {
  const r = frames.find(
    (x) =>
      x.client === s.client &&
      x.method.endsWith('Received') &&
      ['ack', 'nack'].includes(x.msg.type) &&
      x.msg.opId === s.msg.clientOpId,
  );
  return {
    client: s.client,
    id: s.msg.clientOpId,
    type: s.msg.type,
    sentTimestamp: s.timestamp,
    receivedTimestamp: r?.timestamp,
    latencyMs: r ? Math.round((r.timestamp - s.timestamp) * 1000 * 100) / 100 : null,
    receipt: r?.payload ?? null,
  };
});
const percentile = (a, p) => a.sort((x, y) => x - y)[Math.ceil(a.length * p) - 1];
const a = d.checks.find((x) => x.stage === 'server-a').body.ops,
  b = d.checks.find((x) => x.stage === 'server-b').body.ops;
const clients = d.checks
  .filter((x) => x.stage === 'after-writes')
  .map((x) => ({
    client: x.client,
    identical: isDeepStrictEqual(
      [...x.ops].sort((a, b) => a.id.localeCompare(b.id)),
      [...(x.client < 2 ? a : b)].sort((a, b) => a.id.localeCompare(b.id)),
    ),
    ids: x.ops.map((o) => o.id),
  }));
const times = receipts.filter((x) => x.receipt && JSON.parse(x.receipt).type === 'ack').map((x) => x.latencyMs);
const reconnect = d.checks.filter((x) => x.stage === 'reconnect').map((x) => ({ ms: x.end - x.start, ready: x.ready }));
const summary = {
  error: d.error ?? null,
  clients,
  roomAIds: a.map((x) => x.id),
  roomBIds: b.map((x) => x.id),
  overlap: a.map((x) => x.id).filter((id) => b.some((x) => x.id === id)),
  receipts,
  latency: {
    n: times.length,
    p50: percentile([...times], 0.5),
    p95: percentile([...times], 0.95),
    max: Math.max(...times),
  },
  reconnect: {
    samples: reconnect,
    n: reconnect.length,
    p50: percentile(
      reconnect.map((x) => x.ms),
      0.5,
    ),
    p95: percentile(
      reconnect.map((x) => x.ms),
      0.95,
    ),
    max: Math.max(...reconnect.map((x) => x.ms)),
  },
};
await Promise.all([
  writeFile(new URL('./round3-summary.json', import.meta.url), JSON.stringify(summary, null, 2)),
  writeFile(new URL('./round3-room-a.json', import.meta.url), JSON.stringify(a, null, 2)),
  writeFile(new URL('./round3-room-b.json', import.meta.url), JSON.stringify(b, null, 2)),
]);
console.log(JSON.stringify(summary, null, 2));
