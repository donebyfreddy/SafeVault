// State kept by the extension. The vault key lives only in chrome.storage.session: memory-only, cleared when the
// browser closes, and not readable from content scripts. Locking wipes it.
import { b64encode, b64decode } from './crypto.js';

export const DEFAULT_LOCK_MINUTES = 5;

export const local = {
  get: async (k) => (await chrome.storage.local.get(k))[k] ?? null,
  set: (k, v) => chrome.storage.local.set({ [k]: v }),
  remove: (k) => chrome.storage.local.remove(k),
};
export const dropboxStore = { get: () => local.get('dropbox'), set: (v) => local.set('dropbox', v) };

export async function getLockMinutes() { return (await local.get('lockMinutes')) ?? DEFAULT_LOCK_MINUTES; }

export async function unlockedKey() {
  const s = await chrome.storage.session.get(['vaultKey', 'lockAt']);
  if (!s.vaultKey) return null;
  if (s.lockAt && Date.now() >= s.lockAt) { await lock(); return null; }
  return b64decode(s.vaultKey);
}

export async function storeKey(raw) {
  await chrome.storage.session.set({ vaultKey: b64encode(raw) });
  await touch();
}

/** Called on every use: pushes the inactivity deadline forward and arms the alarm. */
export async function touch() {
  const minutes = await getLockMinutes();
  await chrome.storage.session.set({ lockAt: Date.now() + minutes * 60_000 });
  await chrome.alarms.create('safevault-lock', { delayInMinutes: Math.max(minutes, 1), periodInMinutes: 1 });
}

export async function lock() {
  await chrome.storage.session.clear();
  await chrome.alarms.clear('safevault-lock');
}
