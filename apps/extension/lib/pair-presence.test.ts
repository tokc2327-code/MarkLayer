import { afterEach, expect, setSystemTime, test } from 'bun:test';
import { startPairPresence } from './pair-presence';

const scrollX = Object.getOwnPropertyDescriptor(window, 'scrollX');
const scrollY = Object.getOwnPropertyDescriptor(window, 'scrollY');
afterEach(() => {
  setSystemTime();
  if (scrollX) Object.defineProperty(window, 'scrollX', scrollX);
  else Reflect.deleteProperty(window, 'scrollX');
  if (scrollY) Object.defineProperty(window, 'scrollY', scrollY);
  else Reflect.deleteProperty(window, 'scrollY');
});

test('光标节流、文档坐标和离开事件', () => {
  setSystemTime(10000);
  Object.defineProperty(window, 'scrollX', { configurable: true, value: 40 });
  Object.defineProperty(window, 'scrollY', { configurable: true, value: 100 });
  const sent: { cursor?: { x: number; y: number; unit: string } | null; type: string; left?: boolean }[] = [];
  const stop = startPairPresence((msg) => sent.push(msg as (typeof sent)[number]));
  window.dispatchEvent(new MouseEvent('mousemove', { clientX: 10, clientY: 20 }));
  setSystemTime(10249);
  window.dispatchEvent(new MouseEvent('mousemove', { clientX: 11, clientY: 21 }));
  expect(sent.filter((v) => v.cursor?.unit)).toHaveLength(1);
  expect(sent[1]?.cursor).toEqual({ x: 50, y: 120, unit: 'css_document_px' });
  setSystemTime(10250);
  window.dispatchEvent(new MouseEvent('mousemove', { clientX: 12, clientY: 22 }));
  expect(sent.filter((v) => v.cursor?.unit)).toHaveLength(2);
  stop();
  expect(sent.at(-1)).toEqual({ type: 'pair_presence', left: true });
});

test('静止时没有光标定时发送', async () => {
  const sent: { cursor?: { x: number; y: number; unit: string } | null; type: string; left?: boolean }[] = [];
  const stop = startPairPresence((msg) => sent.push(msg as (typeof sent)[number]));
  window.dispatchEvent(new MouseEvent('mousemove', { clientX: 1, clientY: 2 }));
  await Bun.sleep(1100);
  expect(sent.filter((v) => v.cursor?.unit)).toHaveLength(1);
  stop();
});
