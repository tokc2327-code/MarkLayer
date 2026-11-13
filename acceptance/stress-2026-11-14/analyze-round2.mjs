import { readFile, writeFile } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';

const data = JSON.parse(await readFile(new URL('./round2-raw.json', import.meta.url), 'utf8'));
const one = (stage) => data.checks.find((entry) => entry.stage === stage);
const server = one('server-a').body.ops;
const comparisons = data.checks
  .filter((entry) => entry.stage === 'final-room-a')
  .map(({ client, ops }) => {
    const actual = new Set(ops.map((op) => op.id));
    const expected = new Set(server.map((op) => op.id));
    return {
      client,
      count: ops.length,
      missing: [...expected].filter((id) => !actual.has(id)),
      extra: [...actual].filter((id) => !expected.has(id)),
      identical: isDeepStrictEqual(ops, server),
    };
  });
const frames = data.events.flatMap((event) => {
  if (!['Network.webSocketFrameSent', 'Network.webSocketFrameReceived'].includes(event.method)) return [];
  try {
    return [
      {
        client: event.client,
        at: event.at,
        direction: event.method,
        message: JSON.parse(event.params.response.payloadData),
      },
    ];
  } catch {
    return [];
  }
});
const receipts = frames
  .filter((frame) => ['ack', 'nack'].includes(frame.message.type))
  .map((frame) => {
    const sent = frames.find(
      (candidate) => candidate.client === frame.client && candidate.message.clientOpId === frame.message.opId,
    );
    return { client: frame.client, ...frame.message, latencyMs: sent ? frame.at - sent.at : null };
  });
const summary = {
  error: data.error ?? null,
  comparisons,
  roomBMatchesServer: isDeepStrictEqual(one('client-room-b').ops, one('server-b').body.ops),
  roomAIds: one('client-room-a-again').ops.map((op) => op.id),
  roomBIds: one('client-room-b').ops.map((op) => op.id),
  offlineMs: one('offline-end').at - one('offline-start').at,
  offlineClientCount: one('offline-client-before-recovery').ops.length,
  reconnectErrors: data.events
    .filter((event) => event.client === 0 && event.method === 'Network.webSocketFrameError')
    .map((event) => event.params.errorMessage),
  receipts,
};
await writeFile(new URL('./round2-summary.json', import.meta.url), JSON.stringify(summary, null, 2));
console.log(JSON.stringify(summary, null, 2));
