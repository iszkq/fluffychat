// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
// Synthetic, offline interoperability peer. No real accounts, keys or tokens.
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';
const requireSdk = createRequire(resolve(process.argv[2], 'package.json'));
const { initAsync } = await import(pathToFileURL(requireSdk.resolve('@matrix-org/matrix-sdk-crypto-wasm')));
const { MSC4108SecureChannel, MSC4108SignInWithQR } = await import(pathToFileURL(requireSdk.resolve('matrix-js-sdk/lib/rendezvous/index.js')));
// SDK logging must not corrupt the JSON-lines test interface.
for (const name of ['log', 'debug', 'info', 'warn', 'error', 'trace']) console[name] = () => {};
await initAsync();
let body = '', revision = 0, approved = false, finished = null, failure = null;
let newDeviceLoggedIn = false;
const delay = () => new Promise(resolve => setTimeout(resolve, 5));
const session = {
  url: 'https://rendezvous.example/session/synthetic',
  etag: '"0"',
  get cancelled() { return false; },
  async send(value) { body = value; this.etag = `"${++revision}"`; },
  async receive() {
    while (this.etag === `"${revision}"`) await delay();
    this.etag = `"${revision}"`;
    return body;
  },
  async close() {},
};
const channel = new MSC4108SecureChannel(session);
const flow = new MSC4108SignInWithQR(channel, false);
await flow.generateCode();
const qrcode = requireSdk('qrcode');
const qr = qrcode.create([{ data: flow.code, mode: 'byte' }], { errorCorrectionLevel: 'L' });
// Raw payload as actually returned by ZXing/CoreImage (data codewords, before
// mode/count/ECI decoding). qr's create() matrix is tested separately in Dart.
function codewords(bytes, countBits) {
  let bits = '0100' + bytes.length.toString(2).padStart(countBits, '0');
  bits += Array.from(bytes, b => b.toString(2).padStart(8, '0')).join('') + '0000';
  bits = bits.padEnd(Math.ceil(bits.length / 8) * 8, '0');
  return Array.from({ length: bits.length / 8 }, (_, i) => parseInt(bits.slice(i * 8, i * 8 + 8), 2));
}
globalThis.fetch = async (url, options) => {
  const target = String(url);
  if (target === 'https://auth.example/device') {
    return Response.json({ device_code: 'synthetic-device-code', user_code: 'TEST',
      verification_uri: 'https://auth.example/verify',
      verification_uri_complete: 'https://auth.example/verify?user_code=TEST',
      expires_in: 60, interval: 0.01 });
  }
  if (target === 'https://auth.example/token') {
    if (!approved) return Response.json({ error: 'authorization_pending' }, { status: 400 });
    newDeviceLoggedIn = true;
    return Response.json({ access_token: 'synthetic-access-token', token_type: 'Bearer', refresh_token: 'synthetic-refresh-token', expires_in: 3600 });
  }
  throw new Error(`External network forbidden in test: ${target}`);
};
const metadata = { device_authorization_endpoint: 'https://auth.example/device', token_endpoint: 'https://auth.example/token' };
(async () => {
  const negotiation = await flow.negotiateProtocols();
  await flow.deviceAuthorizationGrant({ metadata, clientId: 'synthetic-client', deviceId: 'SYNTHETIC_NEW_DEVICE' });
  const tokens = await flow.completeLoginOnNewDevice({ clientId: 'synthetic-client' });
  const result = await flow.shareSecrets();
  finished = { ...result, checkCode: flow.checkCode, serverName: negotiation.serverName,
    tokenReceived: tokens.access_token === 'synthetic-access-token' };
})().catch(error => { failure = String(error); });
const respond = value => process.stdout.write(`${JSON.stringify(value)}\n`);
respond({ qr: Buffer.from(flow.code).toString('base64'),
  raw8: codewords(flow.code, 8), raw16: codewords(flow.code, 16), qrVersion: qr.version });
for await (const line of createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  switch (request.command) {
    case 'get': respond({ body, etag: `"${revision}"` }); break;
    case 'put':
      if (request.etag !== `"${revision}"`) { respond({ status: 412 }); break; }
      body = request.body; ++revision;
      respond({ status: 200, etag: `"${revision}"` }); break;
    case 'approve': approved = true; respond({ ok: true }); break;
    case 'status': respond({ finished, failure, newDeviceLoggedIn, checkCode: flow.checkCode }); break;
    case 'stop': respond({ ok: true }); process.exit(0); break;
    default: respond({ error: 'Unknown command' });
  }
}
process.exit(0);
