// Injected into the page with chrome.scripting.executeScript({ func: fillPage }). It is serialized, so it must
// not reference anything outside itself.
export function fillPage(expectedOrigin, username, password) {
  if (location.origin !== expectedOrigin) return { ok: false, reason: 'origin-changed' };

  const visible = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const usable = (el) => !el.disabled && !el.readOnly && visible(el);
  const inputs = [...document.querySelectorAll('input')].filter(usable);
  const textTypes = ['', 'text', 'email', 'tel', 'search', 'url'];

  const setValue = (el, value) => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    el.focus();
    setter.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };
  const hint = (el) => `${el.name} ${el.id} ${el.autocomplete} ${el.placeholder} ${el.getAttribute('aria-label') || ''}`.toLowerCase();

  const pw = inputs.find((el) => el.type === 'password' && el.autocomplete !== 'new-password') ?? inputs.find((el) => el.type === 'password');
  const candidates = inputs.filter((el) => textTypes.includes(el.type.toLowerCase()));
  let user = null;
  if (pw) {
    const before = candidates.filter((el) => el.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING);
    const sameForm = before.filter((el) => el.form === pw.form);
    const pool = sameForm.length ? sameForm : before;
    user = pool.find((el) => /user|login|email|mail|account/.test(hint(el))) ?? pool[pool.length - 1] ?? null;
  } else {
    // Identifier-first sign-in: only the username/email step is on screen.
    user = candidates.find((el) => /user|login|email|mail|account/.test(hint(el))) ?? null;
  }

  const filled = [];
  if (user && username) { setValue(user, username); filled.push('username'); }
  if (pw && password) { setValue(pw, password); filled.push('password'); }
  return filled.length ? { ok: true, filled } : { ok: false, reason: 'no-fields' };
}
