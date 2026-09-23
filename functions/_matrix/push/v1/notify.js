// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const MAX_REQUEST_BYTES = 64 * 1024;
const NTFY_PUSHKEY_PREFIX = 'ntfy:';

let cachedAccessToken;

const jsonResponse = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });

const encodeBase64Url = (value) => {
  const bytes =
    typeof value === 'string' ? new TextEncoder().encode(value) : value;
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');
};

const decodeBase64 = (value) => {
  const binary = atob(value.replace(/\s/g, ''));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
};

const parseServiceAccount = (secret) => {
  if (!secret) throw new Error('FIREBASE_SERVICE_ACCOUNT is not configured.');

  let json = secret;
  if (!secret.trimStart().startsWith('{')) {
    json = new TextDecoder().decode(decodeBase64(secret));
  }

  const account = JSON.parse(json);
  if (!account.project_id || !account.client_email || !account.private_key) {
    throw new Error('FIREBASE_SERVICE_ACCOUNT is missing required fields.');
  }
  return account;
};

const importPrivateKey = (privateKey) => {
  const der = decodeBase64(
    privateKey
      .replace('-----BEGIN PRIVATE KEY-----', '')
      .replace('-----END PRIVATE KEY-----', ''),
  );
  return crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
};

const createAccessToken = async (account) => {
  const now = Math.floor(Date.now() / 1000);
  if (
    cachedAccessToken?.projectId === account.project_id &&
    cachedAccessToken.expiresAt > now + 60
  ) {
    return cachedAccessToken.value;
  }

  const header = encodeBase64Url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = encodeBase64Url(
    JSON.stringify({
      iss: account.client_email,
      scope: FCM_SCOPE,
      aud: GOOGLE_TOKEN_URL,
      iat: now,
      exp: now + 3600,
    }),
  );
  const unsignedToken = `${header}.${claims}`;
  const key = await importPrivateKey(account.private_key);
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(unsignedToken),
  );
  const assertion = `${unsignedToken}.${encodeBase64Url(new Uint8Array(signature))}`;

  const response = await fetch(GOOGLE_TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!response.ok) {
    throw new Error(`Unable to obtain Firebase access token (${response.status}).`);
  }

  const token = await response.json();
  cachedAccessToken = {
    projectId: account.project_id,
    value: token.access_token,
    expiresAt: now + Number(token.expires_in || 3600),
  };
  return cachedAccessToken.value;
};

const stringValue = (value) =>
  typeof value === 'string' ? value : JSON.stringify(value);

const createMessageData = (notification, device) => {
  const data = {};
  for (const [key, value] of Object.entries(notification)) {
    if (key === 'devices' || value === undefined || value === null) continue;
    data[key] = stringValue(value);
  }

  const safeDevice = {
    app_id: device.app_id,
    data: device.data || {},
    pushkey_ts: device.pushkey_ts,
    tweaks: device.tweaks,
  };
  data.devices = JSON.stringify([safeDevice]);
  return data;
};

const getNtfyTopic = (device) => {
  if (typeof device?.pushkey !== 'string') return null;
  if (!device.pushkey.startsWith(NTFY_PUSHKEY_PREFIX)) return null;
  const topic = device.pushkey.slice(NTFY_PUSHKEY_PREFIX.length).trim();
  return topic || null;
};

const createNtfyMessage = (notification, device) => {
  const roomName = notification.room_name || 'Matrix 房间';
  const sender = notification.sender_display_name || '新消息';
  const unread = notification.counts?.unread;
  const roomId = notification.room_id;
  const eventId = notification.event_id;
  const clientName = device.data?.client_name;
  const query = new URLSearchParams();
  if (eventId) query.set('event', eventId);
  if (clientName) query.set('client', clientName);
  const deepLink = roomId
    ? `im.fluffychat://room/${encodeURIComponent(roomId)}${query.size ? `?${query}` : ''}`
    : 'im.fluffychat://';

  return {
    topic: getNtfyTopic(device),
    title: roomName,
    message: unread ? `${sender} · ${unread} 条未读消息` : `${sender} 有新消息`,
    click: deepLink,
    actions: [
      {
        action: 'view',
        label: '打开 FluffyChat',
        url: deepLink,
        clear: true,
      },
    ],
    tags: ['speech_balloon'],
    priority: notification.prio === 'low' ? 'default' : 'high',
  };
};

const sendToNtfy = async (notification, device, configuredBaseUrl) => {
  const topic = getNtfyTopic(device);
  if (!topic) return null;

  const baseUrl = String(configuredBaseUrl || 'https://ntfy.sh').replace(
    /\/$/,
    '',
  );
  const response = await fetch(baseUrl, {
    method: 'POST',
    headers: {
      'content-type': 'application/json; charset=utf-8',
    },
    body: JSON.stringify(createNtfyMessage(notification, device)),
  });

  if (response.ok) return { rejected: false };
  if (response.status >= 400 && response.status < 500) {
    return { rejected: true };
  }
  return { rejected: false, temporaryFailure: true };
};

const permanentFcmFailure = (status, responseBody) => {
  if (status === 404) return true;
  const details = responseBody?.error?.details;
  if (!Array.isArray(details)) return false;
  return details.some(
    (detail) =>
      detail?.errorCode === 'UNREGISTERED' ||
      detail?.errorCode === 'SENDER_ID_MISMATCH',
  );
};

const sendToDevice = async (account, accessToken, notification, device) => {
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(account.project_id)}/messages:send`,
    {
      method: 'POST',
      headers: {
        authorization: `Bearer ${accessToken}`,
        'content-type': 'application/json; charset=utf-8',
      },
      body: JSON.stringify({
        message: {
          token: device.pushkey,
          data: createMessageData(notification, device),
          android: {
            priority: notification.prio === 'low' ? 'NORMAL' : 'HIGH',
            ttl: '86400s',
          },
        },
      }),
    },
  );

  if (response.ok) return { rejected: false };
  let responseBody;
  try {
    responseBody = await response.json();
  } catch (_) {
    responseBody = null;
  }
  return {
    rejected: permanentFcmFailure(response.status, responseBody),
    temporaryFailure: !permanentFcmFailure(response.status, responseBody),
  };
};

export async function onRequestPost(context) {
  const contentLength = Number(context.request.headers.get('content-length') || 0);
  if (contentLength > MAX_REQUEST_BYTES) {
    return jsonResponse({ error: 'Push request is too large.' }, 413);
  }

  let requestText;
  try {
    requestText = await context.request.text();
  } catch (_) {
    return jsonResponse({ error: 'Unable to read the push request.' }, 400);
  }
  if (new TextEncoder().encode(requestText).byteLength > MAX_REQUEST_BYTES) {
    return jsonResponse({ error: 'Push request is too large.' }, 413);
  }

  let body;
  try {
    body = JSON.parse(requestText);
  } catch (_) {
    return jsonResponse({ error: 'Expected a JSON push request.' }, 400);
  }

  const notification = body?.notification;
  const devices = notification?.devices;
  if (!notification || !Array.isArray(devices)) {
    return jsonResponse({ error: 'Missing notification devices.' }, 400);
  }
  if (devices.length === 0) return jsonResponse({ rejected: [] });
  if (
    devices.some(
      (device) =>
        typeof device?.pushkey !== 'string' || device.pushkey.length === 0,
    )
  ) {
    return jsonResponse({ error: 'A device has no push key.' }, 400);
  }

  let account;
  let accessToken;
  if (devices.some((device) => !getNtfyTopic(device))) {
    try {
      account = parseServiceAccount(context.env.FIREBASE_SERVICE_ACCOUNT);
      accessToken = await createAccessToken(account);
    } catch (error) {
      console.error('Firebase configuration error:', error?.message || error);
      return jsonResponse({ error: 'Push service is not configured.' }, 503);
    }
  }

  const results = await Promise.all(
    devices.map((device) =>
      (getNtfyTopic(device)
        ? sendToNtfy(notification, device, context.env.NTFY_BASE_URL)
        : sendToDevice(account, accessToken, notification, device)
      ).catch((error) => {
        console.error('Unable to contact push service:', error?.message || error);
        return { rejected: false, temporaryFailure: true };
      }),
    ),
  );
  if (results.some((result) => result.temporaryFailure)) {
    return jsonResponse({ error: 'Push service temporarily rejected the push.' }, 502);
  }

  return jsonResponse({
    rejected: devices
      .filter((_, index) => results[index].rejected)
      .map((device) => device.pushkey),
  });
}

export function onRequest() {
  return jsonResponse({ error: 'Method not allowed.' }, 405);
}
