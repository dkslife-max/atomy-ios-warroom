(function () {
  'use strict';
  const mode = __MODE__;
  const options = __OPTIONS__;
  // Credentials are used only in the verified Taiwan login document.
  if (location.origin !== 'https://tw.atomy.com') return JSON.stringify({status: 'wrong-origin'});
  const visible = el => !!(el && el.getClientRects().length);
  const body = document.body && document.body.innerText || '';
  if (/找不到您申請的網頁|找不到您申請的頁面|page not found/i.test(body))
    return JSON.stringify({status: 'page-not-found'});
  if (location.pathname !== '/login' && location.pathname !== '/login/')
    return JSON.stringify({status: 'not-login-page'});
  const user = document.querySelector('#login_id[login-role="login-id"]');
  const password = document.querySelector('#login_pw[login-role="pwd"]');
  const button = document.querySelector('button[login-role="login-button"]');
  if (!visible(user) || !visible(password) || !button) return JSON.stringify({status: 'loading'});
  const error = [...document.querySelectorAll('.mb_form.err .err_msg')].find(visible);
  if (error && error.textContent.trim()) return JSON.stringify({status: 'login-rejected'});
  if (mode === 'fill') {
    if (!options.account || !options.password) return JSON.stringify({status: 'missing-credentials'});
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    for (const [el, value] of [[user, options.account], [password, options.password]]) {
      setter.call(el, value);
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
      el.dispatchEvent(new KeyboardEvent('keyup', {bubbles: true, key: 'Tab'}));
    }
    return JSON.stringify({status: 'filled'});
  }
  const challenge = [...document.querySelectorAll('[login-role="captcha"] iframe, .cf-turnstile iframe, input[autocomplete="one-time-code"]')]
    .some(visible);
  if (mode === 'submit') {
    if (button.disabled) return JSON.stringify({status: challenge ? 'verification-required' : 'not-ready'});
    // Use the site's handlers, including its normal encryption and verification.
    button.click();
    return JSON.stringify({status: 'submitted'});
  }
  return JSON.stringify({status: challenge ? 'verification-required' : 'waiting-result'});
})()
