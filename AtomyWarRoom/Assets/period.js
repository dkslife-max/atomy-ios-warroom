(function () {
  'use strict';
  const request = __OPTIONS__;
  const controls = [...document.querySelectorAll('input,select')].filter(el => el.getClientRects().length);
  const describe = el => [el.name, el.id, el.getAttribute('placeholder'), el.getAttribute('aria-label'),
    el.labels && el.labels[0] && el.labels[0].textContent].filter(Boolean).join(' ').toLowerCase();
  const dateInputs = controls.filter(el => el.tagName === 'INPUT' &&
    (el.type === 'date' || /日期|date|起日|迄日|開始|結束/.test(describe(el)) ||
      /^\d{4}[-/]\d{1,2}[-/]\d{1,2}$/.test(el.value || '')));
  const starts = dateInputs.filter(el => /起|開始|from|start|begin/.test(describe(el)));
  const ends = dateInputs.filter(el => /迄|結束|至|to|end|finish/.test(describe(el)));
  const first = starts[0] || dateInputs[0];
  const second = ends.find(el => el !== first) || dateInputs.find(el => el !== first);
  if (!first || !second) {
    return JSON.stringify({ status: 'unmapped', reason: 'Two date fields were not found',
      candidates: controls.map(el => ({ tag: el.tagName, type: el.type, name: el.name, id: el.id,
        label: describe(el).slice(0, 80) })).slice(0, 50) });
  }
  window.AtomySalesTransport.install(window);
  window.__atomyQueryState = {
    start: request.start, end: request.end, bindings: {start:[first.name,first.id].filter(Boolean),end:[second.name,second.id].filter(Boolean)},
    token: request.queryToken, pending: 0, requests: 0, queryRequests: 0, failed: false,
    submitted: false, changedAt: Date.now(),
    before: [...document.querySelectorAll('table')].map(el => el.textContent).join('|')
  };
  function setValue(el, value) {
    const picker = el._flatpickr;
    const jq = window.jQuery;
    if (picker && typeof picker.setDate === 'function') picker.setDate(value, true, 'Y-m-d');
    else if (jq && jq.fn && typeof jq.fn.datepicker === 'function' && jq(el).hasClass('hasDatepicker')) {
      const parts = value.split('-').map(Number);
      jq(el).datepicker('setDate', new Date(parts[0], parts[1] - 1, parts[2]));
    }
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.dispatchEvent(new KeyboardEvent('keyup', {bubbles: true, key: 'Tab'}));
    el.dispatchEvent(new Event('blur', {bubbles: true}));
  }
  const shortcut = [...document.querySelectorAll('button,a')].find(el => el.getClientRects().length &&
    (request.start.endsWith('-01') && request.end.endsWith('-15')
      ? /1日\s*[~～－-]\s*15日/.test(el.textContent || '')
      : request.start.endsWith('-16') ? /16日\s*[~～－-]\s*最後一日/.test(el.textContent || '') : false));
  const now = new Date();
  const currentMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  if (shortcut && request.start.slice(0, 7) === currentMonth && (first.readOnly || second.readOnly)) shortcut.click();
  setValue(first, request.start);
  setValue(second, request.end);
  const controlDatesRetained = first.value === request.start && second.value === request.end;
  function applyHiddenRange() {
    const scope=first.form||second.form||document;
    for(const el of scope.querySelectorAll('input[name],input[id]')) {
      if(el===first||el===second)continue;
      const role=window.AtomySalesTransport.role(el.name||el.id,window.__atomyQueryState.bindings);
      if(role)el.value=window.AtomySalesTransport.formatDate(request[role],el.value);
      else if(/^(page|pageNo|pageNum|pageIndex|currentPage|pageIdx)$/i.test(el.name||el.id)&&/^\d+$/.test(el.value))
        el.value=el.value==='0'?'0':'1';
    }
  }
  applyHiddenRange();
  const form=first.form||second.form;
  if(form) {
    form.addEventListener('submit',applyHiddenRange,{capture:true,once:true});
  }
  // Keep the site's current page size. Changing it can reset its date filter.
  const pageSize = 'preserved';
  const buttons = [...document.querySelectorAll('button,input[type=submit],input[type=button],a')]
    .filter(el => el.getClientRects().length);
  const isSearch = el => /^(查詢|搜尋|搜索|search|query)$/i.test(
    [el.textContent, el.value, el.getAttribute('aria-label')].filter(Boolean).join(' ').replace(/\s+/g, ' ').trim());
  const afterDates = el => !!(second.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING);
  let search = null;
  for (let parent = second.parentElement; parent && !search; parent = parent.parentElement) {
    if (parent.contains(first)) search = buttons.find(el => parent.contains(el) && afterDates(el) && isSearch(el));
  }
  if (search) setTimeout(() => {
    const state = window.__atomyQueryState;
    if (state && state.token === request.queryToken) {
      state.submitted = true;
      state.changedAt = Date.now();
      search.click();
    }
  }, 0);
  return JSON.stringify({ status: search ? 'submitted' : 'dates-set-search-not-found',
    start: request.start, end: request.end, controlStart: first.value, controlEnd: second.value, controlDatesRetained, pageSize, clickedSearch: !!search });
})()
