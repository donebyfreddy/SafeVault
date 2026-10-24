// Dropbox OAuth 2 with PKCE (no client secret) and the one download the extension needs. Mirrors Dropbox.swift.
export const VAULT_PATH = '/vault.db';

function base64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export async function makePKCE() {
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(48)));
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return { verifier, challenge: base64url(new Uint8Array(digest)) };
}

export function randomState() { return base64url(crypto.getRandomValues(new Uint8Array(16))); }

export function authorizeUrl({ appKey, redirectUri, challenge, state }) {
  const u = new URL('https://www.dropbox.com/oauth2/authorize');
  u.search = new URLSearchParams({
    client_id: appKey, response_type: 'code', code_challenge: challenge, code_challenge_method: 'S256',
    token_access_type: 'offline', redirect_uri: redirectUri, state,
  }).toString();
  return u.toString();
}

/** Extracts the code from the redirect URL, rejecting a mismatched state. */
export function codeFromRedirect(redirectedUrl, state) {
  const p = new URL(redirectedUrl).searchParams;
  if (p.get('error')) throw new Error(`Dropbox: ${p.get('error_description') || p.get('error')}`);
  if (p.get('state') !== state) throw new Error('Dropbox sign-in was tampered with (state mismatch).');
  const code = p.get('code');
  if (!code) throw new Error('Dropbox did not return a code.');
  return code;
}

async function tokenRequest(body, fetchFn) {
  const r = await fetchFn('https://api.dropboxapi.com/oauth2/token', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(body).toString(),
  });
  if (!r.ok) throw new Error('Dropbox rejected the sign-in. Check the app key and the redirect URI.');
  return r.json();
}

export async function exchangeCode({ appKey, redirectUri, code, verifier }, fetchFn = fetch, now = Date.now()) {
  const j = await tokenRequest({ code, grant_type: 'authorization_code', client_id: appKey, redirect_uri: redirectUri, code_verifier: verifier }, fetchFn);
  if (!j.access_token || !j.refresh_token) throw new Error('Dropbox did not return a refresh token.');
  return { appKey, accessToken: j.access_token, refreshToken: j.refresh_token, expiresAt: now + (j.expires_in ?? 14400) * 1000 };
}

/** Returns a valid access token, refreshing it when needed. `store` is { get(): auth|null, set(auth) }. */
export async function validAccessToken(store, fetchFn = fetch, now = Date.now()) {
  const auth = await store.get();
  if (!auth) throw new Error('Not connected to Dropbox.');
  if (auth.expiresAt > now + 60_000) return auth.accessToken;
  const j = await tokenRequest({ grant_type: 'refresh_token', refresh_token: auth.refreshToken, client_id: auth.appKey }, fetchFn);
  if (!j.access_token) throw new Error('Dropbox did not return an access token.');
  const next = { ...auth, accessToken: j.access_token, expiresAt: now + (j.expires_in ?? 14400) * 1000 };
  await store.set(next);
  return next.accessToken;
}

/** Downloads vault.db. Returns { bytes, rev }. */
export async function downloadVault(store, fetchFn = fetch) {
  const token = await validAccessToken(store, fetchFn);
  const r = await fetchFn('https://content.dropboxapi.com/2/files/download', {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Dropbox-API-Arg': JSON.stringify({ path: VAULT_PATH }) },
  });
  if (r.status === 409) throw new Error('vault.db was not found in your Dropbox app folder. Sync it from SafeVault first.');
  if (r.status === 401) throw new Error('Dropbox session expired. Reconnect.');
  if (!r.ok) throw new Error(`Dropbox error ${r.status}.`);
  let rev = null;
  try { rev = JSON.parse(r.headers.get('Dropbox-API-Result') || '{}').rev ?? null; } catch { /* rev is optional */ }
  return { bytes: new Uint8Array(await r.arrayBuffer()), rev };
}
