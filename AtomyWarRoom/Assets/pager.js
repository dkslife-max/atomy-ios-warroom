(function () {
  'use strict';
  const label = el => [el.textContent, el.getAttribute('aria-label'), el.getAttribute('title')]
    .filter(Boolean).join(' ').replace(/\s+/g, ' ').trim();
  const candidates = [...document.querySelectorAll('button,a,[role=button]')]
    .filter(el => el.getClientRects().length && !el.disabled &&
      el.getAttribute('aria-disabled') !== 'true' && !/disabled/i.test(String(el.className || '')));
  const table = [...document.querySelectorAll('table')].find(el => el.getClientRects().length &&
    /會員編號|會員號碼/.test(el.querySelector('tr')?.textContent || '') &&
    /PV/i.test(el.querySelector('tr')?.textContent || ''));
  if (!table) return JSON.stringify({clicked: false, reason: 'Purchase table not found'});
  const next = candidates.find(el => (table.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING) &&
    /下一頁|下頁|next(?:\s+page)?|^\s*[›»>]\s*$/i.test(label(el)));
  if (!next) return JSON.stringify({ clicked: false, reason: 'No enabled next-page control' });
  setTimeout(() => next.click(), 0);
  return JSON.stringify({ clicked: true, label: label(next) });
})()
