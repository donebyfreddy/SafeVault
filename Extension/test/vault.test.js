import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseVaultFile, unlockVaultKey, decryptItems } from '../src/crypto.js';
import { matchesFor, matchesPage, hostOf, isFillableOrigin, username, password, searchLogins } from '../src/vault.js';

const dir = new URL('./fixtures/', import.meta.url);
const parsed = parseVaultFile(new Uint8Array(readFileSync(new URL('vault.db', dir))));
const items = await decryptItems(parsed, await unlockVaultKey(readFileSync(new URL('password.txt', dir), 'utf8'), parsed.header));
const names = (url) => matchesFor(items, url).map((i) => i.name);

test('accessors follow the Swift model', () => {
  const ex = items.find((i) => i.name === 'Example');
  assert.equal(username(ex), 'alex@example.com');
  assert.equal(password(ex), 'vX9#kQ2$mT7!pL4z ñ✓');
});

test('matches by domain, ignoring www, and includes subdomains', () => {
  assert.deepEqual(names('https://example.com/login'), ['Example']);
  assert.deepEqual(names('https://www.example.com/'), ['Example']);
  assert.deepEqual(names('https://accounts.example.com/'), ['Example']);
});

test('does not match look-alike or parent domains', () => {
  assert.deepEqual(names('https://evil-example.com/'), []);
  assert.deepEqual(names('https://example.com.evil.io/'), []);
  assert.deepEqual(names('https://com/'), []);
  assert.equal(matchesPage({ fields: [{ label: 'Website', value: 'https://login.example.com' }] }, 'https://example.com'), false);
});

test('skips archived items and non-logins', () => {
  assert.ok(!names('https://example.com').includes('Old'));
  assert.ok(!names('https://example.com').includes('Bank card'));
});

test('plain http is refused except on localhost; the port in the item must match', () => {
  assert.deepEqual(names('http://example.com/'), []);
  assert.deepEqual(names('http://localhost:8799/'), ['Local form']);
  assert.deepEqual(names('http://localhost:9999/'), []);
  assert.equal(isFillableOrigin('javascript:alert(1)'), false);
  assert.equal(isFillableOrigin('chrome://settings'), false);
});

test('hostOf tolerates stored sites without a scheme', () => {
  assert.deepEqual(hostOf('www.Example.com/path'), { host: 'example.com', port: '' });
  assert.equal(hostOf('ftp://x.com'), null);
  assert.equal(hostOf(''), null);
});

test('search finds by name, user or site and hides archived', () => {
  assert.deepEqual(searchLogins(items, 'alex').map((i) => i.name), ['Example']);
  assert.deepEqual(searchLogins(items, '').map((i) => i.name), ['Example', 'Local form']);
});
