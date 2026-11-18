(function () {
  'use strict';

  const mode = __MODE__;
  const options = __OPTIONS__;
  const txt = el => (el && el.textContent || '').replace(/\s+/g, ' ').trim();
  const clean = s => String(s || '').replace(/\s+/g, ' ').trim();
  const visible = el => !!(el && el.getClientRects().length);
  const matches = (s, words) => words.some(w => s.includes(w));
  function tableData(table) {
    const rows = [...table.querySelectorAll('tr')];
    const explicitHeader = rows.find(r => r.querySelector('th'));
    const first = rows[0];
    if (!first) return { headers: [], rows: [] };
    const firstCells = [...first.children].map(txt);
    const headerRow = explicitHeader || (firstCells.some(c => /會員編號|會員號碼/.test(c)) &&
      firstCells.some(c => /PV/i.test(c)) ? first : null);
    const headers = headerRow ? [...headerRow.children].map(txt) : firstCells.map((_, i) => `col${i + 1}`);
    const data = rows.filter(r => r !== headerRow).map(r => [...r.children].map(txt))
      .filter(cells => cells.some(Boolean));
    return { headers, rows: data };
  }

  const tables = [...document.querySelectorAll('table')].filter(visible).map(tableData)
    .filter(t => t.headers.length);
  const forms = [...document.querySelectorAll('input,select,button')].filter(visible).map((el, index) => {
    const label = el.labels && el.labels.length ? txt(el.labels[0]) : '';
    return {
      index,
      tag: el.tagName.toLowerCase(),
      type: clean(el.getAttribute('type')),
      name: clean(el.getAttribute('name')),
      id: clean(el.id),
      label: clean(label || el.getAttribute('aria-label') || el.getAttribute('placeholder') || txt(el)).slice(0, 80),
      options: el.tagName === 'SELECT' ? [...el.options].map(o => clean(o.text)).slice(0, 30) : undefined
    };
  }).filter(f => f.type !== 'password' && f.type !== 'hidden');

  const loginFields = [...document.querySelectorAll('input[type=password]')].some(visible);
  const page = { url: location.origin + location.pathname, title: document.title, loginFields };
  if (mode === 'inspect') {
    return JSON.stringify({ page, tables: tables.map(t => ({ headers: t.headers, rowCount: t.rows.length })), forms });
  }

  if (mode === 'identity') {
    const bodyText = document.body && document.body.innerText || '';
    const selectors = ['[data-member-id]', '[data-user-id]', '.member-id', '#memberId', '[name=memberId]'];
    let memberId = '';
    for (const selector of selectors) {
      const el = document.querySelector(selector);
      const value = clean(el && (el.getAttribute('data-member-id') || el.getAttribute('data-user-id') || el.value || txt(el)));
      if (/^[A-Za-z0-9-]{5,20}$/.test(value)) { memberId = value; break; }
    }
    if (!memberId && /我的現況/.test(bodyText)) {
      const intro = bodyText.split('我的現況')[0].slice(-1200);
      const candidates = [...intro.matchAll(/(?:^|\s)(S?\d{6,12})(?=\s|$)/g)].map(match => match[1]);
      if (candidates.length) memberId = candidates[candidates.length - 1];
    }
    return JSON.stringify({ page, memberId, pageNotFound: /找不到您申請的網頁|找不到您申請的頁面|page not found/i.test(bodyText),
      sessionEvidence: !loginFields && !!memberId ? 'member-id-visible' : 'not-proven' });
  }

  const patterns = mode === 'purchase'
    ? ['購買', '訂單', 'PV', '會員編號', '會員號碼', '左右', '線別', 'purchase', 'order']
    : ['會員', '推薦', '安置', '上線', '左', '右', 'member', 'sponsor', 'placement'];
  const scored = tables.map((t, index) => ({
    index,
    score: t.headers.reduce((n, h) => n + (matches(h.toLowerCase(), patterns.map(x => x.toLowerCase())) ? 1 : 0), 0) +
      (mode === 'purchase' && t.rows.some(r => r.length >= 9 && /^(左|右)$/.test(r[0])) ? 3 : 0),
    table: t
  })).sort((a, b) => b.score - a.score || b.table.rows.length - a.table.rows.length);
  const chosen = scored[0];
  if (!chosen || chosen.score < 2) {
    return JSON.stringify({ page, status: 'unmapped', reason: 'No matching visible table', candidates: tables.map(t => t.headers) });
  }
  const result = { page, status: 'captured', kind: mode, headers: chosen.table.headers, rows: chosen.table.rows, rowCount: chosen.table.rows.length };
  if (mode === 'purchase') {
    const bodyText = document.body && document.body.innerText || '';
    const sideTotal = label => {
      const found = bodyText.match(new RegExp(label + '\\s*總和\\s*([-+−－]?[\\d,]+)\\s*PV', 'i'));
      return found ? Number(found[1].replace(/,/g, '').replace(/^[−－]/, '-')) : null;
    };
    const countMatch = bodyText.match(/全部\s*([\d,]+)(?=\s*(?:左|[|｜]))/);
    result.officialSummary = { count: countMatch ? Number(countMatch[1].replace(/,/g, '')) : null,
      leftPv: sideTotal('左'), rightPv: sideTotal('右') };
    const find = re => result.headers.findIndex(h => re.test(h));
    const fixed = result.rows.some(r => r.length >= 9 && /^(左|右)$/.test(r[0])) ||
      (result.headers.length >= 9 && /日期/.test(result.headers[3]) &&
        /會員編號/.test(result.headers[5]) && /PV/i.test(result.headers[8]));
    const mapping = {
      side: find(/左.?右|線別|位置|side/i),
      date: find(/日期|購買日|銷售日|date/i),
      member: find(/會員編號|會員號碼|會員ID|custNo/i),
      name: find(/會員姓名|姓名|name/i),
      order: find(/訂單|訂貨|order/i),
      pv: find(/\bPV\b|點數/i)
    };
    if (fixed) for (const [key, index] of Object.entries({ side: 0, date: 3, member: 5, name: 6, order: 7, pv: 8 })) {
      if (mapping[key] < 0) mapping[key] = index;
    }
    result.mapping = mapping;
    result.period = { start: options.start || '', end: options.end || '' };
    const totals = { leftPv: 0, rightPv: 0, unknownSidePv: 0, validRows: 0, invalidRows: 0, outOfPeriodRows: 0 };
    const records = [], rejected = [];
    for (const [sourceIndex, cells] of result.rows.entries()) {
      const rawDate = clean(cells[mapping.date]);
      const match = rawDate.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})/);
      const date = match ? `${match[1]}-${match[2].padStart(2, '0')}-${match[3].padStart(2, '0')}` : '';
      const member = clean(cells[mapping.member]).replace(/\s/g, '');
      const rawPv = clean(cells[mapping.pv]).replace(/[,\s]/g, '').replace(/^[−－]/, '-');
      const pv = Number(rawPv);
      const side = clean(cells[mapping.side]);
      const reason = !date ? '日期無法辨識' : !/^(?:S)?\d{6,12}$/i.test(member) ? '會員編號無法辨識' :
        !/^[+-]?\d+$/.test(rawPv) || !Number.isSafeInteger(pv) ? 'PV 無法辨識' : '';
      if (reason) {
        totals.invalidRows++;
        rejected.push({sourceIndex, reason, cells});
        continue;
      }
      const item = { date, member, name: clean(cells[mapping.name]), order: clean(cells[mapping.order]), pv,
        sourceSide: side, sourceIndex, sourceType: fixed ? clean(cells[1]) : '',
        sourceAllocation: fixed ? clean(cells[2]) : '', sourceCompany: fixed ? clean(cells[4]) : '' };
      records.push(item);
      totals.validRows++;
      if (side === '左') totals.leftPv += pv;
      else if (side === '右') totals.rightPv += pv;
      else totals.unknownSidePv += pv;
      if (result.period.start && result.period.end && (date < result.period.start || date > result.period.end)) totals.outOfPeriodRows++;
    }
    result.records = records;
    const recordDates = records.map(row => row.date).sort();
    result.dataDateRange = {start: recordDates[0] || '', end: recordDates.at(-1) || ''};
    result.rejected = rejected;
    result.reconciliation = totals;
    const dateValues = [...document.querySelectorAll('input')].filter(visible).map(el => el.value);
    const emptyTable = result.rows.every(cells => cells.every(cell => !cell) ||
      (cells.length === 1 && /不存在|沒有|無資料|無數據|no data|조회.*없/i.test(cells[0])));
    const dateEvidence = options.dateEvidence || (window.__atomyQueryState && window.__atomyQueryState.dateEvidence);
    if (options.queryReady && emptyTable && !records.length && result.officialSummary.count === 0 &&
        result.officialSummary.leftPv === 0 && result.officialSummary.rightPv === 0 &&
        mapping.date >= 0 && mapping.member >= 0 && mapping.pv >= 0 &&
        dateEvidence && dateEvidence.observed && dateEvidence.start === options.start && dateEvidence.end === options.end &&
        options.start && options.end && dateValues.includes(options.start) && dateValues.includes(options.end)) {
      result.emptyVerifiedDateRange = true;
      result.rows = [];
      result.rowCount = 0;
      return JSON.stringify(result);
    }
    if (mapping.side < 0 || mapping.date < 0 || mapping.member < 0 || mapping.pv < 0 || !records.length) {
      result.status = 'captured-needs-mapping';
    } else if (totals.outOfPeriodRows) {
      result.status = 'captured-period-mismatch';
    }
  }
  return JSON.stringify(result);
})()
