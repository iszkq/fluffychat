import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { after, test } from 'node:test';

import { createPushGatewayServer } from './server.mjs';

const servers = [];

after(async () => {
  await Promise.all(
    servers.map(
      (server) => new Promise((resolve) => server.close(resolve)),
    ),
  );
});

const listen = async (server) => {
  servers.push(server);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
};

test('converts Matrix push data into a readable ntfy notification', async () => {
  let published;
  const ntfy = await listen(
    createServer(async (request, response) => {
      if (request.url === '/v1/health') {
        response.end('{"healthy":true}');
        return;
      }
      let body = '';
      for await (const chunk of request) body += chunk;
      published = JSON.parse(body);
      response.end('{"event":"message"}');
    }),
  );
  const gateway = await listen(
    createPushGatewayServer({ NTFY_BASE_URL: ntfy }),
  );

  const response = await fetch(`${gateway}/_matrix/push/v1/notify`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      notification: {
        room_name: '测试房间',
        sender_display_name: '张三',
        counts: { unread: 2 },
        room_id: '!room:example.org',
        event_id: '$event',
        devices: [
          {
            pushkey: 'ntfy:fluffychat-test',
            data: { client_name: 'FluffyChat iOS' },
          },
        ],
      },
    }),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { rejected: [] });
  assert.equal(published.topic, 'fluffychat-test');
  assert.equal(published.title, '测试房间');
  assert.equal(published.message, '张三 · 2 条未读消息');
  assert.match(published.click, /^im\.fluffychat:\/\/room\//);
  assert.equal(published.actions[0].url, published.click);
});

test('reports ntfy failures as temporary failures', async () => {
  const ntfy = await listen(
    createServer((request, response) => {
      response.writeHead(503);
      response.end('unavailable');
    }),
  );
  const gateway = await listen(
    createPushGatewayServer({ NTFY_BASE_URL: ntfy }),
  );

  const response = await fetch(`${gateway}/_matrix/push/v1/notify`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      notification: { devices: [{ pushkey: 'ntfy:fluffychat-test' }] },
    }),
  });

  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {
    error: 'Push service temporarily rejected the push.',
  });
});
