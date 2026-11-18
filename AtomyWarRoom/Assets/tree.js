(function () {
  'use strict';
  const request = __OPTIONS__;
  const done = value => window.AtomyPrototypeResult.complete(request.token, JSON.stringify(value));
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  const url = new URL('/myoffice/genealogy/tree', location.origin);
  url.searchParams.set('level', '2');
  url.searchParams.set('dropYn', 'Y');
  url.searchParams.set('otherCustNo', request.member);
  fetch(url.toString(), {
    method: 'GET', credentials: 'same-origin',
    headers: { Accept: 'application/json, text/plain, */*' },
    signal: controller.signal
  }).then(async response => {
    const body = await response.text();
    let rows;
    try { rows = JSON.parse(body); } catch (_) { rows = null; }
    if (!Array.isArray(rows)) {
      done({ member: request.member, httpStatus: response.status, rootFound: false,
        rowCount: 0, error: 'Response is not a JSON array' });
      return;
    }
    const root = rows.find(row => String(row.custNo || '').trim() === request.member);
    const rootDepth = Number(root && root.lrnkDcnt);
    const direct = rows.filter(row => Number(row.lrnkDcnt) === rootDepth + 1);
    done({ member: request.member, httpStatus: response.status, rootFound: !!root,
      rowCount: rows.length, fields: rows[0] ? Object.keys(rows[0]) : [],
      leftChildren: direct.filter(row => row.trctLocCd === 'L').length,
      rightChildren: direct.filter(row => row.trctLocCd === 'R').length,
      rows });
  }).catch(error => done({ member: request.member, httpStatus: 0, rootFound: false,
    rowCount: 0, error: String(error && error.message || error) }))
    .finally(() => clearTimeout(timer));
})()
