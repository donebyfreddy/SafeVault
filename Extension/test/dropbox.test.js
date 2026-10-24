import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { makePKCE, authorizeUrl, codeFromRedirect, exchangeCode, validAccessToken, downloadVault } from '../src/dropbox.js';

const json = (o, status = 200) => ({ ok: status < 300, status, json: async () => o });

test('PKCE challenge is the S256 of the verifier', async () => {
  const { verifier, challenge } = await makePKCE();
  assert.equal(challenge, createHash('sha256').update(verifier).digest('base64url'));
  assert.match(verifier, /^[A-Za-z0-9_-]{64}$/);
});

test('authorize URL carries PKCE, offline access and state', () => {
  const u = new URL(authorizeUrl({ appKey: 'K', redirectUri: 'https://x.chromiumapp.org/', challenge: 'C', state: 'S' }));
  const p = Object.fromEntries(u.searchParams);
  assert.equal(u.origin + u.pathname, 'https://www.dropbox.com/oauth2/authorize');
  assert.deepEqual([p.client_id, p.code_challenge, p.code_challenge_method, p.token_access_type, p.state], ['K', 'C', 'S256', 'offline', 'S']);
  assert.equal(p.client_secret, undefined);
});

test('redirect handling rejects a wrong state and errors', () => {
  assert.equal(codeFromRedirect('https://x/?code=abc&state=S', 'S'), 'abc');
  assert.throws(() => codeFromRedirect('https://x/?code=abc&state=EVIL', 'S'), /state/);
  assert.throws(() => codeFromRedirect('https://x/?error=access_denied', 'S'), /access_denied/);
});

test('code exchange sends the verifier and no secret', async () => {
  let body;
  const auth = await exchangeCode({ appKey: 'K', redirectUri: 'R', code: 'c', verifier: 'v' }, async (url, init) => {
    body = new URLSearchParams(init.body);
    return json({ access_token: 'A', refresh_token: 'R1', expires_in: 100 });
  }, 1000);
  assert.equal(body.get('code_verifier'), 'v');
  assert.equal(body.has('client_secret'), false);
  assert.deepEqual(auth, { appKey: 'K', accessToken: 'A', refreshToken: 'R1', expiresAt: 101000 });
});

test('expired access token is refreshed and saved; fresh one is reused', async () => {
  let saved = null, calls = 0;
  const store = { get: async () => ({ appKey: 'K', accessToken: 'old', refreshToken: 'RT', expiresAt: 0 }), set: async (v) => { saved = v; } };
  const f = async () => { calls++; return json({ access_token: 'new', expires_in: 3600 }); };
  assert.equal(await validAccessToken(store, f, 10_000), 'new');
  assert.equal(saved.refreshToken, 'RT');
  const fresh = { get: async () => ({ accessToken: 'ok', expiresAt: 1e12 }), set: async () => {} };
  assert.equal(await validAccessToken(fresh, f, 10_000), 'ok');
  assert.equal(calls, 1);
});

test('download returns bytes and rev; maps 409 to a helpful error', async () => {
  const store = { get: async () => ({ accessToken: 'T', expiresAt: 1e15 }), set: async () => {} };
  let req;
  const ok = async (url, init) => { req = { url, init }; return { ok: true, status: 200, headers: new Headers({ 'Dropbox-API-Result': '{"rev":"r1"}' }), arrayBuffer: async () => new Uint8Array([1, 2]).buffer }; };
  const r = await downloadVault(store, ok);
  assert.deepEqual([...r.bytes], [1, 2]);
  assert.equal(r.rev, 'r1');
  assert.equal(req.init.headers.Authorization, 'Bearer T');
  assert.equal(JSON.parse(req.init.headers['Dropbox-API-Arg']).path, '/vault.db');
  await assert.rejects(downloadVault(store, async () => ({ ok: false, status: 409 })), /not found/);
});
