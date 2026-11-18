(function () {
  'use strict';
  const request = __OPTIONS__;
  const bridge = window.AtomyPrototypeResult;
  const levels = [50, 40, 30, 20, 15, 10, 7, 5, 3, 2];
  const cap = 1001;
  const state = request.checkpoint || {
    root: request.root, queue: [{ id: request.root, baseDepth: 1 }], seen: [],
    chunks: 0, requests: 0, paceMs: 2500, mode: 'full'
  };
  const seen = new Set(state.seen);
  const queued = new Set([...seen, ...state.queue.map(item => item.id)]);
  let lastRequestAt = 0;
  window.__atomyScanStop = false;
  const wait = async ms => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (window.__atomyScanStop) throw Error('scan-cancelled');
      await new Promise(resolve => setTimeout(resolve, Math.min(250, end - Date.now())));
    }
  };

  async function fetchTree(id, level) {
    const uri = new URL('/myoffice/genealogy/tree', location.origin);
    uri.searchParams.set('level', String(level));
    uri.searchParams.set('dropYn', 'Y');
    uri.searchParams.set('otherCustNo', id);
    for (let attempt = 0; attempt < 7; attempt++) {
      if (window.__atomyScanStop) throw Error('scan-cancelled');
      bridge.scanRequest(request.token, state.chunks, state.requests + 1,
        state.queue.length + 1, level, attempt + 1);
      const elapsed = Date.now() - lastRequestAt;
      if (elapsed < state.paceMs) await wait(state.paceMs - elapsed);
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 30000);
      const cancelWatch = setInterval(() => { if (window.__atomyScanStop) controller.abort(); }, 250);
      let response, body;
      try {
        response = await fetch(uri.toString(), { method: 'GET', credentials: 'same-origin',
          headers: { Accept: 'application/json, text/plain, */*' }, signal: controller.signal });
        body = await response.text();
      } finally {
        clearTimeout(timer);
        clearInterval(cancelWatch);
        lastRequestAt = Date.now();
        state.requests++;
      }
      if (response.ok) {
        let rows;
        try { rows = JSON.parse(body); } catch (_) { throw Error('組織 API 回傳不是 JSON'); }
        if (!Array.isArray(rows)) throw Error('組織 API 回傳不是陣列');
        state.paceMs = Math.max(2000, state.paceMs - 50);
        return rows;
      }
      const throttled = response.status === 429 ||
        (response.status === 500 && /請求量過大|稍後再試/.test(body));
      if (throttled && attempt < 6) {
        state.paceMs = Math.min(6000, Math.max(state.paceMs + 500, Math.round(state.paceMs * 1.2)));
        const delay = [3000, 6000, 12000, 20000, 30000, 45000][attempt];
        bridge.scanBackoff(request.token, response.status, delay);
        await wait(delay);
        continue;
      }
      if (response.status >= 500 && attempt < 2) {
        const delay = attempt ? 6000 : 3000;
        bridge.scanBackoff(request.token, response.status, delay);
        await wait(delay);
        continue;
      }
      throw Error(`組織 API HTTP ${response.status}`);
    }
    throw Error('組織 API 重試已達上限');
  }

  function inspect(id, level, rows) {
    const clean = rows.filter(row => /^(?:S)?\d{6,12}$/i.test(String(row.custNo || '').trim()));
    const root = clean.find(row => String(row.custNo).trim() === id);
    if (!root) throw Error('區塊缺少查詢根會員');
    const rootDepth = Number(root.lrnkDcnt);
    if (!Number.isFinite(rootDepth)) throw Error('根會員缺少層級資料');
    if (clean.length >= cap) return { capped: true };
    const maxDepth = Math.max(...clean.map(row => Number(row.lrnkDcnt)).filter(Number.isFinite));
    const boundaryDepth = rootDepth + level - 1;
    if (maxDepth > boundaryDepth) throw Error('組織 API 層級超過預期邊界');
    const boundary = maxDepth === boundaryDepth
      ? clean.filter(row => Number(row.lrnkDcnt) === boundaryDepth) : [];
    return { clean, rootDepth, boundary, capped: false };
  }

  async function run() {
    try {
      while (state.queue.length) {
        if (window.__atomyScanStop) { bridge.scanPaused(request.token); return; }
        const item = state.queue.shift();
        if (seen.has(item.id)) continue;
        let chunk = null;
        const itemLevels=item.levelLimit?levels.filter(level=>level<=item.levelLimit):levels;
        for (const level of itemLevels) {
          const rows = await fetchTree(item.id, level);
          const candidate = inspect(item.id, level, rows);
          if (!candidate.capped) { chunk = candidate; break; }
        }
        if (!chunk) throw Error('level=2 仍碰到回傳上限，無法安全切分');
        for (const row of item.followBoundary===false?[]:chunk.boundary) {
          const id = String(row.custNo).trim();
          if (id === item.id || queued.has(id)) continue;
          queued.add(id);
          state.queue.push({ id, baseDepth: item.baseDepth + Number(row.lrnkDcnt) - chunk.rootDepth });
        }
        seen.add(item.id);
        state.seen = [...seen];
        state.chunks++;
        const persisted = bridge.saveScanChunk(request.token, JSON.stringify({
          item, rows: chunk.clean, rootDepth: chunk.rootDepth, checkpoint: state
        }));
        if (persisted !== 'ok') throw Error(`本機組織存檔失敗：${persisted}`);
        bridge.scanProgress(request.token, state.chunks, state.requests, state.queue.length);
      }
      if (window.__atomyScanStop) bridge.scanPaused(request.token);
      else bridge.scanDone(request.token, request.root);
    } catch (error) {
      if (window.__atomyScanStop) bridge.scanPaused(request.token);
      else bridge.scanFailed(request.token, String(error && error.message || error));
    }
  }
  run();
})()
