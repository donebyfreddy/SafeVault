import { parseVaultFile, unlockVaultKey, decryptItems, b64encode, b64decode } from './crypto.js';
import { matchesFor, searchLogins, username, password, website, isFillableOrigin } from './vault.js';
import { makePKCE, randomState, authorizeUrl, codeFromRedirect, exchangeCode, downloadVault } from './dropbox.js';
import { fillPage } from './fill.js';
import { local, dropboxStore, unlockedKey, storeKey, touch, lock } from './session.js';

const view = document.getElementById('view');
const lockBtn = document.getElementById('lockBtn');

function el(tag, props = {}, ...kids) {
  const e = Object.assign(document.createElement(tag), props);
  for (const k of kids) e.append(k);
  return e;
}
const show = (...nodes) => view.replaceChildren(...nodes);
const errorLine = () => el('p', { className: 'err', role: 'alert' });

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

// ---- Setup: connect Dropbox ------------------------------------------------------------------------------

function setupView() {
  lockBtn.hidden = true;
  const redirect = chrome.identity.getRedirectURL();
  const key = el('input', { id: 'appkey', autocomplete: 'off', spellcheck: false, placeholder: 'Dropbox app key' });
  const err = errorLine();
  const btn = el('button', { textContent: 'Connect Dropbox' });
  btn.onclick = async () => {
    err.textContent = '';
    const appKey = key.value.trim();
    if (!appKey) { err.textContent = 'Enter your Dropbox app key.'; return; }
    btn.disabled = true;
    try {
      const { verifier, challenge } = await makePKCE();
      const state = randomState();
      const redirected = await chrome.identity.launchWebAuthFlow({ url: authorizeUrl({ appKey, redirectUri: redirect, challenge, state }), interactive: true });
      const code = codeFromRedirect(redirected, state);
      await dropboxStore.set(await exchangeCode({ appKey, redirectUri: redirect, code, verifier }));
      await render();
    } catch (e) { err.textContent = e.message; btn.disabled = false; }
  };
  show(
    el('p', {}, 'Use the same Dropbox app key you typed in SafeVault. In the Dropbox App Console, add this redirect URI to that app:'),
    el('code', { textContent: redirect }),
    el('label', {}, 'App key', key), btn, err,
  );
  key.focus();
}

// ---- Unlock ----------------------------------------------------------------------------------------------

async function fetchVaultBytes() {
  try {
    const { bytes, rev } = await downloadVault(dropboxStore);
    await local.set('vaultCache', { rev, data: b64encode(bytes) });
    return { bytes, offline: false };
  } catch (e) {
    const cached = await local.get('vaultCache');
    if (cached) return { bytes: b64decode(cached.data), offline: true };
    throw e;
  }
}

function lockedView() {
  lockBtn.hidden = true;
  const pw = el('input', { type: 'password', id: 'master', autocomplete: 'off', placeholder: 'Master password' });
  const err = errorLine();
  const btn = el('button', { textContent: 'Unlock' });
  const form = el('form', { style: 'display:flex;flex-direction:column;gap:10px' }, el('label', {}, 'Master password', pw), btn, err);
  form.onsubmit = async (ev) => {
    ev.preventDefault();
    err.textContent = '';
    btn.disabled = true; btn.textContent = 'Unlocking…';
    try {
      const { bytes } = await fetchVaultBytes();
      const parsed = parseVaultFile(bytes);
      const raw = await unlockVaultKey(pw.value, parsed.header);
      await decryptItems(parsed, raw);  // proves the vault is readable before keeping the key
      pw.value = '';
      await storeKey(raw);
      await render();
    } catch (e) { err.textContent = e.message; btn.disabled = false; btn.textContent = 'Unlock'; }
  };
  show(form, disconnectLink());
  pw.focus();
}

function disconnectLink() {
  const b = el('button', { className: 'link', textContent: 'Disconnect Dropbox' });
  b.onclick = async () => {
    await lock();
    await local.remove('dropbox'); await local.remove('vaultCache');
    await render();
  };
  return b;
}

// ---- Unlocked: list and fill -----------------------------------------------------------------------------

async function unlockedView(rawKey) {
  lockBtn.hidden = false;
  const tab = await activeTab();
  const status = el('p', { className: 'status' }, 'Loading…');
  show(status);
  let items, offline = false;
  try {
    const res = await fetchVaultBytes();
    offline = res.offline;
    items = await decryptItems(parseVaultFile(res.bytes), rawKey);
  } catch (e) { await lock(); return lockedView(); }
  await touch();

  const pageUrl = tab?.url || '';
  const canFill = isFillableOrigin(pageUrl);
  const search = el('input', { type: 'search', placeholder: 'Search logins', autocomplete: 'off' });
  const list = el('div', { className: 'list' });
  const err = errorLine();

  const fill = async (item) => {
    err.textContent = '';
    try {
      const [res] = await chrome.scripting.executeScript({
        target: { tabId: tab.id }, func: fillPage, args: [new URL(pageUrl).origin, username(item), password(item)],
      });
      if (!res?.result?.ok) { err.textContent = 'No login fields found on this page.'; return; }
      await touch();
      window.close();
    } catch { err.textContent = 'Could not fill this page.'; }
  };

  const draw = () => {
    const q = search.value.trim();
    const found = q ? searchLogins(items, q) : matchesFor(items, pageUrl);
    list.replaceChildren(...found.map((item) => {
      const b = el('button', { className: 'row', disabled: !canFill }, el('b', { textContent: item.name }), el('span', { textContent: username(item) || website(item) || '' }));
      b.onclick = () => fill(item);
      return b;
    }));
    if (!found.length) list.append(el('p', {}, q ? 'No logins match.' : 'No saved logins for this site.'));
  };
  search.oninput = draw;
  draw();
  status.textContent = [canFill ? null : 'Autofill works on https pages (and localhost).', offline ? 'Offline: showing the last downloaded copy.' : null].filter(Boolean).join(' ');
  show(search, list, err, status);
}

lockBtn.onclick = async () => { await lock(); await render(); };

async function render() {
  if (!(await dropboxStore.get())) return setupView();
  const key = await unlockedKey();
  return key ? unlockedView(key) : lockedView();
}

render();
