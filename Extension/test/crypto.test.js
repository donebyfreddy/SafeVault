import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseVaultFile, unlockVaultKey, decryptItems, VaultError } from '../src/crypto.js';

const fixture = (n) => readFileSync(new URL(`./fixtures/${n}`, import.meta.url));
const bytes = new Uint8Array(fixture('vault.db'));
const password = fixture('password.txt').toString('utf8');

test('decrypts a vault.db written by the Swift app', async () => {
  const parsed = parseVaultFile(bytes);
  assert.equal(parsed.header.kdf.iterations, 600000);
  const items = await decryptItems(parsed, await unlockVaultKey(password, parsed.header));
  assert.deepEqual(items.map((i) => i.name).sort(), ['Bank card', 'Example', 'Local form', 'Old']);
  const ex = items.find((i) => i.name === 'Example');
  assert.equal(ex.fields.find((f) => f.label === 'Password').value, 'vX9#kQ2$mT7!pL4z ñ✓');
});

test('NFKC: compatibility and decomposed forms of the password unlock too', async () => {
  const { header } = parseVaultFile(bytes);
  assert.ok(password.includes('ﬁ'));
  assert.equal((await unlockVaultKey(password.replace('ﬁ', 'fi'), header)).length, 32);
  assert.equal((await unlockVaultKey(password.normalize('NFD'), header)).length, 32);
});

test('wrong or empty password is reported as wrongPassword', async () => {
  const { header } = parseVaultFile(bytes);
  for (const pw of ['nope', '']) await assert.rejects(unlockVaultKey(pw, header), (e) => e instanceof VaultError && e.code === 'wrongPassword');
});

test('a modified payload is rejected', async () => {
  const parsed = parseVaultFile(bytes);
  const raw = await unlockVaultKey(password, parsed.header);
  parsed.payload[parsed.payload.length - 1] ^= 1;
  await assert.rejects(decryptItems(parsed, raw), (e) => e.code === 'corrupted');
});

test('the payload cannot be opened with the wrapping context (context binding)', async () => {
  const parsed = parseVaultFile(bytes);
  const swapped = { ...parsed, payload: Uint8Array.from(Buffer.from(parsed.header.wrappedKey, 'base64')) };
  await assert.rejects(decryptItems(swapped, await unlockVaultKey(password, parsed.header)), (e) => e.code === 'corrupted');
});

test('rejects garbage, wrong format and newer versions', () => {
  const enc = (o) => new TextEncoder().encode(JSON.stringify(o));
  const good = JSON.parse(Buffer.from(bytes).toString());
  assert.throws(() => parseVaultFile(new Uint8Array([1, 2, 3])), (e) => e.code === 'corrupted');
  assert.throws(() => parseVaultFile(enc({ ...good, format: 'other' })), (e) => e.code === 'corrupted');
  assert.throws(() => parseVaultFile(enc({ ...good, version: 3 })), (e) => e.code === 'unsupportedVersion');
});
