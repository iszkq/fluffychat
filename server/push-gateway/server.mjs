import { createServer } from 'node:http';

const notifyPath = '/_matrix/push/v1/notify';
const maxRequestBytes = 64 * 1024;

const sendJson = (response, status, body) => {
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  response.end(JSON.stringify(body));
};

const readBody = async (request) => {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxRequestBytes) return null;
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
};

const getTopic = (pushkey) =>
  typeof pushkey === 'string' && pushkey.startsWith('ntfy:')
    ? pushkey.slice('ntfy:'.length).trim()
    : null;

const createClickUrl = (notification, device) => {
  const roomId = notification.room_id;
  if (!roomId) return 'im.fluffychat://';

  const query = new URLSearchParams();
  if (notification.event_id) query.set('event', notification.event_id);
  if (device.data?.client_name) {
    query.set('client', device.data.client_name);
  }
  return `im.fluffychat://room/${encodeURIComponent(roomId)}${query.size ? `?${query}` : ''}`;
};

const createNtfyMessage = (notification, device, topic) => {
  const roomName = notification.room_name || 'Matrix 房间';
  const sender = notification.sender_display_name || '新消息';
  const unread = notification.counts?.unread;
  const click = createClickUrl(notification, device);
  return {
    topic,
    title: roomName,
    message: unread ? `${sender} · ${unread} 条未读消息` : `${sender} 有新消息`,
    click,
    actions: [
      {
        action: 'view',
        label: '打开 FluffyChat',
        url: click,
        clear: true,
      },
    ],
    tags: ['speech_balloon'],
    priority: notification.prio === 'low' ? 3 : 4,
  };
};

const publishToNtfy = async (baseUrl, notification, device, topic) => {
  const response = await fetch(baseUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json; charset=utf-8' },
    body: JSON.stringify(createNtfyMessage(notification, device, topic)),
    signal: AbortSignal.timeout(10000),
  });
  if (response.ok) return;
  const details = await response.text();
  throw new Error(`ntfy returned ${response.status}: ${details.slice(0, 300)}`);
};

export const createPushGatewayServer = (environment = process.env) => {
  const configuredBaseUrl = environment.NTFY_BASE_URL?.trim();
  if (!configuredBaseUrl) throw new Error('NTFY_BASE_URL is required.');
  const baseUrl = configuredBaseUrl.replace(/\/$/, '');

  return createServer(async (request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    if (pathname === '/healthz' && request.method === 'GET') {
      try {
        const health = await fetch(`${baseUrl}/v1/health`, {
          signal: AbortSignal.timeout(5000),
        });
        const body = await health.json();
        sendJson(response, health.ok && body.healthy ? 200 : 503, body);
      } catch (error) {
        console.error('Unable to reach ntfy:', error);
        sendJson(response, 503, { healthy: false });
      }
      return;
    }

    if (pathname !== notifyPath || request.method !== 'POST') {
      sendJson(response, pathname === notifyPath ? 405 : 404, {
        error: pathname === notifyPath ? 'Method not allowed.' : 'Not found.',
      });
      return;
    }

    try {
      if (Number(request.headers['content-length'] || 0) > maxRequestBytes) {
        sendJson(response, 413, { error: 'Push request is too large.' });
        return;
      }
      const rawBody = await readBody(request);
      if (rawBody === null) {
        sendJson(response, 413, { error: 'Push request is too large.' });
        return;
      }
      const body = JSON.parse(rawBody.toString('utf8'));
      const notification = body?.notification;
      const devices = notification?.devices;
      if (!notification || !Array.isArray(devices)) {
        sendJson(response, 400, { error: 'Missing notification devices.' });
        return;
      }

      for (const device of devices) {
        const topic = getTopic(device?.pushkey);
        if (!topic) {
          sendJson(response, 400, { error: 'Unsupported push key.' });
          return;
        }
        await publishToNtfy(baseUrl, notification, device, topic);
      }
      sendJson(response, 200, { rejected: [] });
    } catch (error) {
      console.error('Unable to publish Matrix notification:', error);
      sendJson(response, 502, {
        error: 'Push service temporarily rejected the push.',
      });
    }
  });
};

if (process.argv[1] && process.argv[1].endsWith('server.mjs')) {
  const port = Number(process.env.PORT || 3000);
  createPushGatewayServer().listen(port, '0.0.0.0', () => {
    console.log(`FluffyChat push gateway listening on ${port}`);
  });
}
