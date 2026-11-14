import { App } from '../components/App';
import css from '../entrypoints/content/style.css?inline';
import { initHost } from '../lib/host';
import { mountOverlay } from '../lib/overlay-mount';
import { visible } from '../lib/ui-state';

const send = (message: unknown) =>
  (window as unknown as { chrome?: { webview?: { postMessage: (value: unknown) => void } } }).chrome?.webview?.postMessage(message);
initHost({
  capabilities: { persist: false, share: false, contextMenu: false, triage: false, batch: false },
  actions: { onOpMade: (op) => send({ type: 'annotate:submit', op, dpr: devicePixelRatio }) },
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
