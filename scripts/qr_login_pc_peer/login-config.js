// Public application configuration. No user credentials or account registration.
export const DEFAULT_HOMESERVER = 'https://mtx01.cc';
export const DEFAULT_AUTH_ISSUER = 'https://account.mtx01.cc/';
// Dedicated native public client, device-code + refresh grants, no client secret.
export const DEFAULT_OAUTH_CLIENT_ID = '01M6DCKTJRVZ4M34DVW6VZDT7Q';
// These explicitly supported regional frontends share Matrix account IDs but
// each publishes its own OAuth issuer. Keep grants on the selected frontend.
export const REGIONAL_DOMAINS = ['mtx01.cc', 'mtxhk1.com', 'mtxus1.com'];
const regionalIssuers = new Set(REGIONAL_DOMAINS.map(domain => `https://account.${domain}/`));
const SERVER_KEY = 'mxchat.login-server';

export function sameLoginHomeserver(left, right) {
  const parse = value => {
    try { const uri = new URL(value); return uri.protocol === 'https:' && !uri.username && !uri.password && !uri.search && !uri.hash && uri.pathname === '/' && !uri.port ? uri.hostname : null; }
    catch { return null; }
  };
  const regionalHosts = new Set(REGIONAL_DOMAINS.flatMap(domain => [domain, `matrix.${domain}`]));
  if (left === right) return true;
  return regionalHosts.has(parse(left)) && regionalHosts.has(parse(right));
}

export function getLoginServer() {
  try { return localStorage.getItem(SERVER_KEY) || DEFAULT_HOMESERVER; }
  catch { return DEFAULT_HOMESERVER; }
}
export function rememberLoginServer(value) {
  try { localStorage.setItem(SERVER_KEY, value); } catch { /* Login also works without local preferences. */ }
}

export function getQrClientId(metadata, configuredId = '') {
  if (configuredId.trim()) return configuredId.trim();
  if (regionalIssuers.has(metadata.issuer)) return DEFAULT_OAUTH_CLIENT_ID;
  throw new Error('此服务器的扫码登录尚未接通，请使用账号登录或切换服务器。');
}
