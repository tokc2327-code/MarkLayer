import type { AnnotationOp, Diagnosis } from '@marklayer/types/ops';
import { MAX_DIAGNOSIS_RECENT } from '@marklayer/types/relay';

function cleanText(value: string): string {
  return value
    .replace(/https?:\/\/[^\s"'<>]+/gi, (raw) => safePageUrl(raw))
    .replace(/\bBearer\s+[^\s,;]+/gi, 'Bearer [redacted]')
    .replace(/([?&](?:token|key|auth|session|user|email|code|secret)[^=]*=)[^&#\s]*/gi, '$1[redacted]')
    .replace(/\b(user|account|session|token|secret|api[_-]?key)(?:[_ -]?id)?\s*[:=]\s*[^\s,;]+/gi, '$1=[redacted]')
    .replace(/[\w.+-]+@[\w.-]+\.[a-z]{2,}/gi, '[redacted]')
    .replace(/\b[\da-f]{8}-[\da-f-]{27,}\b/gi, '[id]')
    .replace(/\b[a-z\d_-]{24,}\b/gi, '[id]');
}

function safePageUrl(raw: string): string {
  try {
    const url = new URL(raw);
    url.username = '';
    url.password = '';
    const path = url.pathname
      .split('/')
      .map((part, i, all) => {
        const prior = all[i - 1]?.toLowerCase();
        if (
          [
            'user',
            'users',
            'account',
            'accounts',
            'session',
            'sessions',
            'token',
            'tokens',
            'profile',
            'profiles',
          ].includes(prior ?? '')
        )
          return ':id';
        return /^[\da-f]{8}-[\da-f-]{27,}$/i.test(part) || /^[a-z\d_-]{24,}$/i.test(part) ? ':id' : part;
      })
      .join('/');
    return `${url.origin}${path}`;
  } catch {
    return '';
  }
}

function scrub<T>(value: T): T {
  if (typeof value === 'string') return cleanText(value) as T;
  if (Array.isArray(value)) return value.map(scrub) as T;
  if (value && typeof value === 'object')
    return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, scrub(child)])) as T;
  return value;
}

/** Conservative MCP-side package when no extension-collected live snapshot exists yet. */
export function buildStoredDiagnosis(op: AnnotationOp, capturedAt = Date.now(), pageHref?: string): Diagnosis {
  const meta = op.tool === 'comment' ? op.meta : undefined;
  /** An inspect annotation carries selector/rect instead of an anchor target. */
  const target = 'target' in op && op.target ? scrub(op.target) : undefined;
  const sourceUrl = meta?.url ? safePageUrl(meta.url) : pageHref ? safePageUrl(pageHref) : '';
  const reproductionSteps = [
    ...(sourceUrl ? [`打开页面来源 ${sourceUrl}`] : []),
    ...(target?.selector ? [`定位批注目标 ${cleanText(target.selector)}`] : []),
  ];
  const pageErrors = (meta?.errors ?? []).map((error) => ({
    ...error,
    message: cleanText(error.message),
    ...(error.source ? { source: safePageUrl(error.source) } : {}),
  }));
  const networkFailures = (meta?.networkErrors ?? []).map((error) => ({ ...error, url: safePageUrl(error.url) }));
  return normalizeDiagnosis(op, {
    capturedAt,
    source: 'stored-annotation',
    pageUrl: sourceUrl || null,
    ...(target ? { target } : {}),
    pageErrorCount: pageErrors.length,
    pageErrors: pageErrors.slice(-MAX_DIAGNOSIS_RECENT),
    networkFailureCount: networkFailures.length,
    networkFailures: networkFailures.slice(-MAX_DIAGNOSIS_RECENT),
    reproductionSteps: reproductionSteps.slice(0, 6),
    partial: true,
  });
}

/** Apply the same privacy filtering to live observations before attaching them to an op. */
export function sanitizeDiagnosis(diagnosis: Diagnosis): Diagnosis {
  return scrub(diagnosis);
}

/** Upgrade older snapshots and generate a bounded, evidence-linked reading. */
export function normalizeDiagnosis(op: AnnotationOp, raw: Diagnosis): Diagnosis {
  const live = raw.source === 'live-page';
  const missing: string[] = [];
  const pageUrl = raw.pageUrl ?? (op.tool === 'comment' && op.meta?.url ? safePageUrl(op.meta.url) : null);
  if (!pageUrl) missing.push('pageUrl：未记录页面地址');
  if (!raw.target) missing.push('target：批注未记录目标元素或目标已失效');
  if (!raw.targetPointerEvents) missing.push('targetPointerEvents：未采集目标指针样式');
  if (!raw.hierarchy) missing.push('hierarchy：未采集目标的 iframe 和 shadow 层级');
  if (!raw.hitTest || (live && raw.partial)) missing.push('hitTest：目标或命中元素不可用，无法判断覆盖');
  const hitChain = raw.hitChain ?? [];
  if (!raw.hitChain || !live) missing.push('hitChain：未采集可用的实时命中链');
  const viewport = {
    width: raw.viewport?.width ?? null,
    height: raw.viewport?.height ?? null,
    dpr: raw.viewport?.dpr ?? raw.viewport?.devicePixelRatio ?? null,
    devicePixelRatio: raw.viewport?.devicePixelRatio ?? raw.viewport?.dpr ?? null,
    scale: raw.viewport?.scale ?? null,
    scrollX: raw.viewport?.scrollX ?? null,
    scrollY: raw.viewport?.scrollY ?? null,
  };
  for (const [key, value] of Object.entries(viewport))
    if (value === null) missing.push(`viewport.${key}：未采集视口数据`);
  if (!live) {
    missing.push('pageErrors：仅有批注快照，缺少实时页面错误');
    missing.push('networkFailures：仅有批注快照，缺少实时网络失败记录');
  }
  const target = raw.target?.selector?.slice(0, 45) ?? '未记录目标';
  const symptom = 'text' in op ? cleanText(op.text).slice(0, 65) : '未记录批注正文';
  const reasons: string[] = [];
  const targetHit = hitChain.find((item) => item.isTarget);
  if (raw.targetPointerEvents === 'none')
    reasons.push(`目标指针事件被禁用（targetPointerEvents: none；target.selector: ${target}）`);
  else if (targetHit?.pointerEvents === 'none')
    reasons.push(`目标指针事件被禁用（hitChain: ${targetHit.selector} pointer-events: none）`);
  const blocker = hitChain[0];
  if (raw.hitTest?.covered && blocker && !blocker.isTarget)
    reasons.push(
      `命中点被其他元素覆盖（hitTest.covered: true；hitChain: ${blocker.selector.slice(0, 45)}，z-index: ${blocker.zIndex.slice(0, 20)}）`,
    );
  const evidence = reasons.length ? `原因线索：${reasons.join('；')}。` : '原因证据不足，尚不能定性。';
  const exclusions =
    raw.hitTest && !raw.hitTest.covered && live && !raw.partial ? '命中点未发现覆盖（hitTest.covered: false）。' : '';
  const missingText = missing.length
    ? `缺少证据：${missing.map((item) => item.split('：')[0]).join('、')}；原因见 missing。`
    : '';
  const prefix = `症状：${symptom}（target.selector: ${target}）。${evidence}${exclusions}`;
  const summary = `${prefix}${missingText}`.slice(0, 400);
  return scrub({
    ...raw,
    target: raw.target ?? null,
    hierarchy: raw.hierarchy ?? null,
    hitTest: raw.hitTest ?? null,
    targetPointerEvents: raw.targetPointerEvents ?? null,
    completeness: live && !raw.partial && missing.length === 0 ? 'live' : 'partial',
    missing,
    summary,
    pageUrl,
    viewport,
    hitChain,
  });
}
