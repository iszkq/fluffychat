// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

const UPSTREAM_ORIGIN = 'https://image.527012.xyz';
const MAX_PATH_LENGTH = 1024;

const jsonResponse = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'access-control-allow-origin': '*',
    },
  });

const isSafePath = (path) =>
  typeof path === 'string' &&
  path.length > 0 &&
  path.length <= MAX_PATH_LENGTH &&
  !path.startsWith('/') &&
  !path.includes('\\') &&
  !path.split('/').includes('..');

const fetchUpstream = (path) => {
  if (!isSafePath(path)) return null;
  const encodedPath = path
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/');
  return fetch(`${UPSTREAM_ORIGIN}/${encodedPath}`, {
    headers: { accept: '*/*' },
  });
};

async function proxyIndex(request) {
  let upstream;
  try {
    upstream = await fetch(`${UPSTREAM_ORIGIN}/index.json`, {
      headers: { accept: 'application/json' },
    });
  } catch (_) {
    return jsonResponse({ error: 'Unable to reach the sticker service.' }, 502);
  }
  if (!upstream.ok) {
    return jsonResponse({ error: 'Sticker index is unavailable.' }, 502);
  }

  let index;
  try {
    index = await upstream.json();
  } catch (_) {
    return jsonResponse({ error: 'Sticker index is invalid.' }, 502);
  }
  if (!index || !Array.isArray(index.items)) {
    return jsonResponse({ error: 'Sticker index is invalid.' }, 502);
  }

  const origin = new URL(request.url).origin;
  index.items = index.items
    .filter((item) => item && isSafePath(item.path))
    .map((item) => {
      const proxyUrl = `${origin}/api/stickers?path=${encodeURIComponent(item.path)}`;
      return { ...item, url: proxyUrl, thumbUrl: proxyUrl };
    });
  return new Response(JSON.stringify(index), {
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'public, max-age=300',
      'access-control-allow-origin': '*',
    },
  });
}

async function proxySticker(path) {
  let upstream;
  try {
    upstream = await fetchUpstream(path);
  } catch (_) {
    return jsonResponse({ error: 'Unable to reach the sticker service.' }, 502);
  }
  if (upstream == null) {
    return jsonResponse({ error: 'Invalid sticker path.' }, 400);
  }
  if (!upstream.ok || !upstream.body) {
    return jsonResponse({ error: 'Sticker is unavailable.' }, upstream.status === 404 ? 404 : 502);
  }
  const contentType = upstream.headers.get('content-type') || '';
  if (!contentType.startsWith('image/')) {
    return jsonResponse({ error: 'Upstream response is not an image.' }, 502);
  }
  const headers = {
    'content-type': contentType,
    'cache-control': 'public, max-age=86400',
    'access-control-allow-origin': '*',
  };
  const contentLength = upstream.headers.get('content-length');
  if (contentLength) headers['content-length'] = contentLength;
  return new Response(upstream.body, {
    headers,
  });
}

export async function onRequestGet(context) {
  const url = new URL(context.request.url);
  if (url.searchParams.get('index') === '1') {
    return proxyIndex(context.request);
  }
  return proxySticker(url.searchParams.get('path'));
}

export function onRequestOptions() {
  return new Response(null, {
    status: 204,
    headers: {
      'access-control-allow-origin': '*',
      'access-control-allow-methods': 'GET, OPTIONS',
    },
  });
}

export function onRequest() {
  return jsonResponse({ error: 'Method not allowed.' }, 405);
}
