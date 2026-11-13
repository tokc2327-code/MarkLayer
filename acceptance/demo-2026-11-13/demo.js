async (page) => {
  const out = 'C:/Users/xxc/orca/workspaces/visual collaboration/demo-2026-11-13/acceptance/demo-2026-11-13';
  const id = 'demo' + Date.now();
  const base = 'http://127.0.0.1:5199';
  const room = await fetch(`${base}/api/${id}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ ops: [], url: 'https://example.com', width: 1280, expires_in: 86400 }),
  });
  if (!room.ok) throw Error(`room ${room.status}`);
  const context = await page
    .context()
    .browser()
    .newContext({ viewport: { width: 1280, height: 900 } });
  await context.addInitScript(() => localStorage.setItem('ml-support', JSON.stringify({ answers: 3 })));
  const p = await context.newPage();
  let frame = 0,
    busy = false;
  const capture = setInterval(async () => {
    if (busy || p.isClosed()) return;
    busy = true;
    try {
      await p.screenshot({ path: out + '/frame-' + String(frame++).padStart(4, '0') + '.png' });
    } catch {
    } finally {
      busy = false;
    }
  }, 500);
  const pause = (ms) => p.waitForTimeout(ms);
  const caption = async (text) => {
    await p.evaluate((text) => {
      let e = document.getElementById('demo-caption');
      if (!e) {
        e = document.createElement('div');
        e.id = 'demo-caption';
        Object.assign(e.style, {
          position: 'fixed',
          top: '60px',
          right: '20px',
          zIndex: '2147483647',
          background: '#142333',
          color: 'white',
          padding: '14px 18px',
          borderRadius: '10px',
          font: '16px sans-serif',
          maxWidth: '430px',
          boxShadow: '0 3px 15px #0006',
          pointerEvents: 'none',
        });
        document.body.appendChild(e);
      }
      e.textContent = text;
    }, text);
  };
  const call = async (name, args = {}) => {
    const r = await fetch(`${base}/s/${id}/mcp?agent=scripted-demo`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }),
    });
    const t = await r.text();
    if (!r.ok) throw Error(t);
    const line = t.split('\n').find((x) => x.startsWith('data: '));
    const result = JSON.parse(line.slice(6));
    if (result.error || result.result?.isError) throw Error(t);
    return result.result;
  };
  try {
    await p.goto(`${base}/s/${id}`, { waitUntil: 'domcontentloaded' });
    await p.getByRole('button', { name: 'Rectangle', exact: true }).waitFor();
    await pause(4000);
    await caption('Scripted browser demo: annotate a real page');
    await pause(2500);
    await p.getByRole('button', { name: 'Rectangle', exact: true }).click();
    await p.mouse.move(350, 230);
    await p.mouse.down();
    await p.mouse.move(800, 310, { steps: 40 });
    await p.mouse.up();
    await pause(1800);
    await caption('Rectangle created in the live viewer');
    await p.getByRole('button', { name: 'Drawing tools' }).click();
    await p.getByRole('menuitemradio', { name: /Highlight/ }).click();
    await p.mouse.move(360, 380);
    await p.mouse.down();
    await p.mouse.move(750, 380, { steps: 40 });
    await p.mouse.up();
    await pause(1800);
    await caption('Highlight created; add a comment pin');
    await p.getByRole('button', { name: 'Comment', exact: true }).click();
    await p.mouse.click(600, 430);
    await p.locator('textarea[name=comment]').fill('How can we make this introduction clearer?');
    await pause(1000);
    await p.getByRole('button', { name: 'Post', exact: true }).click();
    await pause(2500);
    await caption('Scripted MCP client calls marklayer_read_page');
    const read = await call('marklayer_read_page');
    await pause(2500);
    await caption('MCP: marklayer_list_annotations reads the comment and nearby marks');
    const listed = await call('marklayer_list_annotations');
    const data = JSON.parse(listed.content.find((x) => x.type === 'text').text);
    if (data.count !== 1) throw Error('Expected one comment');
    const a = data.annotations[0];
    const kinds = a.visualContext?.annotations?.map((x) => x.kind) || [];
    if (!kinds.includes('rectangle') || !kinds.includes('highlight'))
      throw Error('Missing visual context: ' + JSON.stringify(kinds));
    await pause(3000);
    await caption('Scripted response via MCP marklayer_reply (no AI model)');
    const reply =
      'Suggestion: lead with the purpose of this example domain, then move the usage restriction into a shorter second sentence.';
    await call('marklayer_reply', { id: a.id, text: reply });
    await pause(4000);
    await p.getByRole('button', { name: 'Annotations panel' }).click();
    await p.getByText('How can we make this introduction clearer?', { exact: true }).last().click();
    await p.getByText(reply, { exact: true }).last().waitFor({ state: 'visible', timeout: 10000 });
    const detail = await call('marklayer_get_annotation', { id: a.id });
    if (!JSON.stringify(detail).includes(reply)) throw Error('Reply readback missing');
    await caption('Reply confirmed in the original thread via MCP readback');
    await pause(3000);
    await p.screenshot({ path: out + '/thumbnail.png' });
    clearInterval(capture);
    while (busy) await new Promise((r) => setTimeout(r, 50));
    await context.close();
    return { frames: frame, room: id, annotation: a.id, read, listed, detail };
  } catch (e) {
    clearInterval(capture);
    while (busy) await new Promise((r) => setTimeout(r, 50));
    await context.close();
    throw e;
  }
};
