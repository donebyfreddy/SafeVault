// Login lookup, mirroring VaultItem in Models.swift (username / password / website accessors).
const ci = (a, b) => a.toLowerCase() === b.toLowerCase();
const nonEmpty = (v) => (typeof v === 'string' && v !== '' ? v : null);
const field = (item, label) => (item.fields || []).find((f) => ci(f.label, label));

export function username(item) {
  const f = field(item, 'Username') ?? (item.fields || []).find((x) => x.type === 'email');
  return nonEmpty(f?.value);
}
export function password(item) {
  const f = field(item, 'Password') ?? (item.fields || []).find((x) => x.type === 'secret' && x.label.toLowerCase().includes('password'));
  return nonEmpty(f?.value);
}
export function website(item) {
  const f = field(item, 'Website') ?? (item.fields || []).find((x) => x.type === 'url');
  return nonEmpty(f?.value);
}

/** Only live (not deleted, not archived) logins that can be filled. */
export function fillableLogins(items) {
  return items.filter((i) => i.kind === 'login' && !i.deleted && !i.archived && (username(i) || password(i)));
}

/** Host (and port) of a stored website or a page URL; tolerates "example.com/path" without a scheme. */
export function hostOf(value) {
  if (!value) return null;
  const s = value.trim();
  try {
    const u = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(s) ? s : `https://${s}`);
    if (!/^https?:$/.test(u.protocol)) return null;
    return { host: u.hostname.replace(/^www\./, '').toLowerCase(), port: u.port };
  } catch { return null; }
}

/** The page may be the item's site or any subdomain of it. A port stored in the item must match. */
export function matchesPage(item, pageUrl) {
  const page = hostOf(pageUrl);
  const site = hostOf(website(item));
  if (!page || !site) return false;
  if (site.port && site.port !== page.port) return false;
  return page.host === site.host || page.host.endsWith(`.${site.host}`);
}

/** Never fill over plain http, except on localhost for development. */
export function isFillableOrigin(pageUrl) {
  try {
    const u = new URL(pageUrl);
    if (u.protocol === 'https:') return true;
    return u.protocol === 'http:' && (u.hostname === 'localhost' || u.hostname === '127.0.0.1' || u.hostname === '[::1]');
  } catch { return false; }
}

export function matchesFor(items, pageUrl) {
  if (!isFillableOrigin(pageUrl)) return [];
  return fillableLogins(items).filter((i) => matchesPage(i, pageUrl)).sort((a, b) => Number(!!b.favorite) - Number(!!a.favorite) || a.name.localeCompare(b.name));
}

export function searchLogins(items, query) {
  const q = query.trim().toLowerCase();
  return fillableLogins(items).filter((i) => !q || i.name.toLowerCase().includes(q) || (username(i) || '').toLowerCase().includes(q) || (website(i) || '').toLowerCase().includes(q))
    .sort((a, b) => a.name.localeCompare(b.name));
}
