// Mirrors Packages/MyVaultKit/Sources/MyVaultKit/{Crypto,VaultFile}.swift. Read-only: nothing here encrypts a vault.
const enc = new TextEncoder();
const dec = new TextDecoder();
const subtle = globalThis.crypto.subtle;

const WRAP_CONTEXT = enc.encode('myvault.key.v1');
const DB_CONTEXT = enc.encode('myvault.db.v2');
const FORMAT = 'safevault-db';
const MAX_DB_VERSION = 2;
const MAX_HEADER_VERSION = 1;

export class VaultError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const corrupted = () => new VaultError('corrupted', 'The vault data is damaged or has been modified.');

export function b64decode(s) {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function b64encode(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

/** Parses vault.db (bytes) and checks format and versions. Returns { header, payload: Uint8Array }. */
export function parseVaultFile(bytes) {
  let c;
  try { c = JSON.parse(dec.decode(bytes)); } catch { throw corrupted(); }
  if (!c || c.format !== FORMAT || typeof c.version !== 'number' || !c.header || typeof c.payload !== 'string') throw corrupted();
  if (c.version > MAX_DB_VERSION) throw new VaultError('unsupportedVersion', 'This vault was created by a newer version of SafeVault.');
  const h = c.header;
  if (!h.kdf || typeof h.kdf.salt !== 'string' || typeof h.wrappedKey !== 'string') throw corrupted();
  if (h.version > MAX_HEADER_VERSION) throw new VaultError('unsupportedVersion', 'This vault was created by a newer version of SafeVault.');
  try { return { header: h, payload: b64decode(c.payload) }; } catch { throw corrupted(); }
}

async function deriveWrapKey(password, kdf) {
  if (kdf.algorithm !== 'pbkdf2-hmac-sha256' || !(kdf.iterations > 0)) throw corrupted();
  // NFKC, like precomposedStringWithCompatibilityMapping in the Swift app.
  const pw = enc.encode(password.normalize('NFKC'));
  const base = await subtle.importKey('raw', pw, 'PBKDF2', false, ['deriveBits']);
  const bits = await subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: b64decode(kdf.salt), iterations: kdf.iterations }, base, 256);
  return subtle.importKey('raw', bits, 'AES-GCM', false, ['decrypt']);
}

/** Opens a blob sealed by VaultCrypto.seal: 0x01 | 12-byte nonce | ciphertext | 16-byte tag. */
async function open(blob, key, context) {
  if (blob.length < 1 + 12 + 16) throw corrupted();
  if (blob[0] !== 1) throw new VaultError('unsupportedVersion', 'Unsupported encryption format.');
  try {
    const plain = await subtle.decrypt({ name: 'AES-GCM', iv: blob.slice(1, 13), additionalData: context, tagLength: 128 }, key, blob.slice(13));
    return new Uint8Array(plain);
  } catch { throw corrupted(); }
}

/** Derives the key from the master password and unwraps the vault key. Returns the raw 32 bytes. */
export async function unlockVaultKey(password, header) {
  if (!password) throw new VaultError('wrongPassword', 'The master password is incorrect.');
  const wrapper = await deriveWrapKey(password, header.kdf);
  let raw;
  try { raw = await open(b64decode(header.wrappedKey), wrapper, WRAP_CONTEXT); }
  catch (e) { throw e.code === 'corrupted' ? new VaultError('wrongPassword', 'The master password is incorrect.') : e; }
  if (raw.length !== 32) throw corrupted();
  return raw;
}

export function importVaultKey(raw) {
  return subtle.importKey('raw', raw, 'AES-GCM', false, ['decrypt']);
}

/** Decrypts the item list of a parsed vault.db with the raw vault key. */
export async function decryptItems(parsed, rawKey) {
  const plain = await open(parsed.payload, await importVaultKey(rawKey), DB_CONTEXT);
  try {
    const items = JSON.parse(dec.decode(plain)).items;
    if (!Array.isArray(items)) throw corrupted();
    return items;
  } catch (e) { throw e instanceof VaultError ? e : corrupted(); }
}
