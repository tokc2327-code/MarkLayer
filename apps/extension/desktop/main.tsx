import { App } from '../components/App';
import css from '../entrypoints/content/style.css?inline';
import { initHost } from '../lib/host';
import { mountOverlay } from '../lib/overlay-mount';
import { operations } from '../lib/ops';
import { activeTool } from '../lib/tool-state';
import { visible } from '../lib/ui-state';

const send = (message: unknown) =>
  (window as unknown as { chrome?: { webview?: { postMessage: (value: unknown) => void } } }).chrome?.webview?.postMessage(message);
const webview = (window as unknown as { chrome?: { webview?: { addEventListener: (type: string, fn: (event: MessageEvent) => void) => void } } }).chrome?.webview;
let nextRequest = 0;
const pending = new Map<number, { resolve: (value: any) => void; reject: (reason: Error) => void }>();
webview?.addEventListener('message', (event) => {
  const message = event.data;
  if (message?.type === 'window:track') {
    operations.value = message.items.map((item: { id: string; num: number; text: string; status: string; color: string; x: number; y: number }) => ({
      id: item.id, tool: 'comment' as const, num: item.num, text: item.text ?? '',
      status: item.status || 'open', color: item.color || '#ef4444', lineWidth: 2, ts: 0,
      x: (item.x - message.origin.x) / devicePixelRatio, y: (item.y - message.origin.y) / devicePixelRatio,
    }));
    requestAnimationFrame(() => {
      const marker = document.querySelector('mark-layer')?.shadowRoot?.querySelector('[data-marker]');
      send({ type: 'window:track:applied', rect: marker?.getBoundingClientRect().toJSON() });
    });
    return;
  }
  const request = pending.get(message?.requestId);
  if (!request) return;
  pending.delete(message.requestId);
  if (message.error) request.reject(new Error(message.error));
  else request.resolve(message.result);
});
function hostRequest(type: string, payload: object): Promise<any> {
  const requestId = ++nextRequest;
  return new Promise((resolve, reject) => {
    pending.set(requestId, { resolve, reject });
    send({ type, requestId, ...payload });
    setTimeout(() => {
      if (pending.delete(requestId)) reject(new Error(`${type} timed out`));
    }, 10000);
  });
}
let selectionStart: { x: number; y: number } | null = null;
let capturedTarget: Promise<unknown> | null = null;
initHost({
  capabilities: { persist: false, share: false, contextMenu: false, triage: false, batch: false },
  actions: { onOpMade: (op) => {
    if (op.tool !== 'area' && op.tool !== 'comment') return;
    const capture = capturedTarget;
    capturedTarget = null;
    if (!capture) return;
    void capture.then((target) => send({ type: 'annotate:submit', op, target })).catch(console.error);
  } },
});
Object.assign(window, {
  marklayerDesktopTrack: (target: unknown) => hostRequest('window:track', { target }),
  marklayerDesktopCapture: (crop: unknown) => hostRequest('capture:element', { crop, dpr: devicePixelRatio }),
});
visible.value = true;
const host = document.createElement('mark-layer');
document.body.append(host);
const shadow = host.attachShadow({ mode: 'open' });
const style = document.createElement('style');
style.textContent = css;
shadow.append(style);
// CSS @property registrations are document-scoped, including for the shadow tree.
const registrations = document.createElement('style');
registrations.textContent = css;
document.head.append(registrations);
const container = document.createElement('div');
shadow.append(container);
mountOverlay({ container, app: <App /> });
shadow.addEventListener('pointerdown', (event) => {
  if (!(event instanceof PointerEvent)) return;
  if ((activeTool.value === 'area' || activeTool.value === 'comment') && event.target instanceof Element && getComputedStyle(event.target).cursor === 'crosshair') {
    selectionStart = { x: event.clientX, y: event.clientY };
  }
}, true);
shadow.addEventListener('pointerup', (event) => {
  if (!(event instanceof PointerEvent)) return;
  if (!selectionStart) return;
  const start = selectionStart;
  selectionStart = null;
  const left = Math.min(start.x, event.clientX), top = Math.min(start.y, event.clientY);
  capturedTarget = hostRequest('capture:target', { rect: { left, top, width: Math.abs(event.clientX - start.x), height: Math.abs(event.clientY - start.y) }, dpr: devicePixelRatio });
}, true);
shadow.addEventListener('pointerdown', (event) => {
  if (event.composedPath().some((node) => node instanceof HTMLTextAreaElement || node instanceof HTMLInputElement)) {
    send({ type: 'window:activate' });
  }
}, true);
shadow.addEventListener('focusout', (event) => {
  if (event.target instanceof HTMLTextAreaElement || event.target instanceof HTMLInputElement) send({ type: 'window:deactivate' });
}, true);
requestAnimationFrame(() => {
  const toolbar = shadow.querySelector('[data-ml-toolbar]');
  const rect = toolbar?.getBoundingClientRect();
  (window as unknown as { chrome?: { webview?: { postMessage: (value: unknown) => void } } }).chrome?.webview?.postMessage({
    type: 'page:ready', toolbar: !!toolbar, rect: rect?.toJSON(), size: [innerWidth, innerHeight],
    style: toolbar ? { left: getComputedStyle(toolbar).left, translate: getComputedStyle(toolbar).translate, transform: getComputedStyle(toolbar).transform } : null,
  });
});
