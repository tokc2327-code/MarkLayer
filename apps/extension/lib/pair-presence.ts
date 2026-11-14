/** 光标最多每 250 毫秒发送一次；超限直接丢弃，不排队。 */
export const CURSOR_INTERVAL_MS = 250;
/** 视口每 5 秒刷新；静止 1 秒后不再发送光标。 */
export const VIEWPORT_INTERVAL_MS = 5000;
export const CURSOR_IDLE_MS = 1000;

export function startPairPresence(send: (message: unknown) => void): () => void {
  let lastCursor = -Infinity;
  let movedAt = -Infinity;
  const viewport = () => {
    const root = document.scrollingElement;
    return {
      unit: 'css_px',
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio,
      documentWidth: root?.scrollWidth ?? 0,
      documentHeight: root?.scrollHeight ?? 0,
    };
  };
  const report = () =>
    send({
      type: 'pair_presence',
      viewport: viewport(),
      ...(Date.now() - movedAt >= CURSOR_IDLE_MS ? { cursor: null } : {}),
    });
  const move = (event: MouseEvent) => {
    const now = Date.now();
    movedAt = now;
    if (now - lastCursor < CURSOR_INTERVAL_MS) return;
    lastCursor = now;
    send({
      type: 'pair_presence',
      viewport: viewport(),
      cursor: { x: event.clientX + window.scrollX, y: event.clientY + window.scrollY, unit: 'css_document_px' },
    });
  };
  const leave = () => send({ type: 'pair_presence', left: true });
  window.addEventListener('mousemove', move);
  window.addEventListener('pagehide', leave);
  const timer = setInterval(report, VIEWPORT_INTERVAL_MS);
  report();
  return () => {
    clearInterval(timer);
    window.removeEventListener('mousemove', move);
    window.removeEventListener('pagehide', leave);
    leave();
  };
}
