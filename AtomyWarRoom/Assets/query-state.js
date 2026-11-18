(function () {
  const request = __OPTIONS__;
  const state = window.__atomyQueryState;
  if (!state) return JSON.stringify({ready: !!request.queryNavigationComplete, pending: 0});
  if (state.token !== request.queryToken) return JSON.stringify({ready: false, reason: 'different-query'});
  if (state.failed) return JSON.stringify({ready: false, failed: true, dateEvidence: state.dateEvidence || {observed:false}});
  const changed = state.before !== [...document.querySelectorAll('table')].map(el => el.textContent).join('|');
  return JSON.stringify({ready: state.submitted && state.pending === 0 &&
    (state.queryRequests > 0 || changed) && Date.now() - state.changedAt >= 1000,
    pending: state.pending, requests: state.requests, dateEvidence: state.dateEvidence || {observed:false}});
})()
