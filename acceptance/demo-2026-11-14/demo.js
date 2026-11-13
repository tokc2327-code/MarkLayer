async (page) => {
  const out = 'acceptance/demo-2026-11-14';
  const base = 'http://127.0.0.1:5199';
  const id = 'acceptdemo' + Date.now();
  const log = { room: id, events: [] };
  const context = await page.context().browser().newContext({ viewport: { width: 1280, height: 900 } });
  await context.addInitScript(() => {
    const Native = window.WebSocket;
    window.WebSocket = new Proxy(Native, { construct(target, args) { const ws = Reflect.construct(target, args); if (String(args[0]).includes('/ws/')) window.__roomSocket = ws; return ws; } });
    localStorage.setItem('ml-support', JSON.stringify({ answers: 3 }));
  });
  const p = await context.newPage();
  let frame = 0;
  const capture = async (stage, count = 2) => { for (let i = 0; i < count; i++) { await p.screenshot({ path: `${out}/frame-${String(frame++).padStart(3, '0')}.png` }); await p.waitForTimeout(500); } log.events.push({ stage, text: (await p.locator('body').innerText()).slice(-1200) }); };
  const call = async (name, args) => {
    const r = await fetch(`${base}/s/${id}/mcp?agent=accept-demo`, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }) });
    const raw = await r.text(); log.events.push({ name, args, status: r.status, raw });
    const line = raw.split('\n').find((s) => s.startsWith('data: '));
    if (!r.ok || !line) throw Error(`MCP ${name}: ${raw}`);
    const data = JSON.parse(line.slice(6)); if (data.error || data.result?.isError) throw Error(`MCP ${name}: ${raw}`);
    return JSON.parse(data.result.content.find((x) => x.type === 'text').text);
  };
  try {
    const room = await fetch(`${base}/api/${id}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ops: [], url: 'https://example.com', width: 1280 }) });
    if (!room.ok) throw Error(`room ${room.status} ${await room.text()}`);
    await p.goto(`${base}/s/${id}`); await p.getByRole('button', { name: 'Comment', exact: true }).waitFor(); await p.waitForTimeout(2500);
    await p.locator('select').selectOption('guide');
    const start = await call('teach_start', { steps: ['选择评论', '选择矩形'] });
    const pid = start.presentationId;
    await call('teach_step', { presentationId: pid, index: 0, caption: '第一步：选择评论工具', toolbarTarget: 'comment' });
    await p.getByText('第一步：选择评论工具', { exact: false }).waitFor(); await capture('guide-step-one', 3);
    await p.getByRole('button', { name: 'Pen', exact: true }).click(); await capture('wrong-click-pen', 2);
    await p.getByRole('button', { name: '暂停', exact: true }).click();
    await call('teach_step', { presentationId: pid, index: 0, caption: '第一步：选择评论工具', toolbarTarget: 'comment', state: 'paused' });
    await capture('pause', 2);
    await p.getByRole('button', { name: '继续', exact: true }).click();
    await call('teach_step', { presentationId: pid, index: 0, caption: '第一步：选择评论工具', toolbarTarget: 'comment', state: 'active' });
    await capture('resume', 2);
    await p.getByRole('button', { name: '下一步', exact: true }).click();
    await call('teach_step', { presentationId: pid, index: 1, caption: '第二步：选择矩形工具', toolbarTarget: 'rectangle' });
    await p.getByText('第二步：选择矩形工具', { exact: false }).waitFor(); await capture('guide-step-two', 3);
    await context.setOffline(true); const socket = await p.evaluate(() => { const s = window.__roomSocket; const state = s?.readyState; s?.close(); return state; });
    log.events.push({ stage: 'offline', socket }); await p.waitForTimeout(2500); await capture('offline', 2);
    await context.setOffline(false); await p.waitForTimeout(9000); await capture('restored', 3);
    await call('teach_step', { presentationId: pid, index: 1, caption: '第二步：连接恢复后继续', toolbarTarget: 'rectangle', state: 'active' });
    await p.getByText('第二步：连接恢复后继续', { exact: false }).waitFor({ timeout: 10000 }); await capture('recovered-step', 3);
    log.completed = true;
  } catch (e) { log.error = String(e); }
  finally { log.frames = frame; await context.close(); }
  return log;
}
