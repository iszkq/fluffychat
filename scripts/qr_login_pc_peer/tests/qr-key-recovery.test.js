import test from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from 'matrix-js-sdk';
import * as wasm from '@matrix-org/matrix-sdk-crypto-wasm';
import { importQrCachedSecrets } from '../src/qr-key-recovery.js';

await wasm.initAsync();
const userId = '@qr-test:example.org';
async function fixture(t) {
  const phone = await wasm.OlmMachine.initialize(new wasm.UserId(userId), new wasm.DeviceId('PHONE'));
  t.after(() => phone.close());
  const setup = await phone.bootstrapCrossSigning(false);
  const signing = JSON.parse(setup.uploadSigningKeysRequest.body);
  const exported = await phone.exportCrossSigningKeys();
  const backup = wasm.BackupDecryptionKey.createRandomKey();
  t.after(() => backup.free());
  const backupInfo = { algorithm: 'm.megolm_backup.v1.curve25519-aes-sha2', version: '1',
    auth_data: { public_key: backup.megolmV1PublicKey.publicKeyBase64 }, count: 0, etag: '0' };
  const backupData = { rooms: {} };
  const signatures = [];
  const deviceKeys = {};
  const keyResponse = () => ({ device_keys: { [userId]: deviceKeys },
    master_keys: { [userId]: signing.master_key },
    self_signing_keys: { [userId]: signing.self_signing_key },
    user_signing_keys: { [userId]: signing.user_signing_key }, failures: {} });
  const client = createClient({ baseUrl: 'https://matrix.example.org', userId, deviceId: 'PC', accessToken: 'synthetic',
    fetchFn: async (url, options) => {
      const path = new URL(url).pathname;
      if (path.endsWith('/keys/upload')) {
        const body = JSON.parse(options.body);
        if (body.device_keys) deviceKeys[body.device_keys.device_id] = body.device_keys;
        return Response.json({ one_time_key_counts: {} });
      }
      if (path.endsWith('/keys/query')) return Response.json(keyResponse());
      if (path.endsWith('/keys/signatures/upload')) { signatures.push(JSON.parse(options.body)); return Response.json({ failures: {} }); }
      if (path.endsWith('/room_keys/version') || path.endsWith('/room_keys/version/1')) return Response.json(backupInfo);
      if (path.endsWith('/room_keys/keys')) return Response.json(backupData);
      throw new Error(`Unexpected external request in offline test: ${path}`);
    } });
  t.after(async () => { await new Promise(resolve => setTimeout(resolve, 50)); client.stopClient(); });
  await client.initRustCrypto({ useIndexedDB: false });
  const api = client.getCrypto();
  const engine = api.olmMachine;
  // Process the actual initial key upload/query requests, just as /sync does.
  for (const request of await engine.outgoingRequests()) {
    if (request.type === wasm.RequestType.KeysUpload) {
      const keys = JSON.parse(request.body).device_keys;
      if (keys) deviceKeys[keys.device_id] = keys;
      await engine.markRequestAsSent(request.id, request.type, JSON.stringify({ one_time_key_counts: {} }));
    } else if (request.type === wasm.RequestType.KeysQuery) {
      await engine.markRequestAsSent(request.id, request.type, JSON.stringify(keyResponse()));
    }
  }
  const bundle = { version: 1, user_id: userId, device_id: 'PC',
    master_key: Object.values(signing.master_key.keys)[0],
    self_signing_key: { public_key: Object.values(signing.self_signing_key.keys)[0], private_key: exported.self_signing_key },
    user_signing_key: { public_key: Object.values(signing.user_signing_key.keys)[0], private_key: exported.userSigningKey },
    backup: { key: backup.toBase64(), backup_version: '1' } };
  exported.free();
  return { client, api, engine, bundle, signatures, backup, phone, backupData };
}

test('real Rust crypto trusts the scanned identity, signs the PC and imports backup without a master seed or SAS', async t => {
  const f = await fixture(t);
  assert.equal((await f.engine.crossSigningStatus()).hasMaster, false);
  await importQrCachedSecrets(f.client, { userId, deviceId: 'PC' }, f.bundle);
  const status = await f.engine.crossSigningStatus();
  assert.equal(status.hasMaster, false);
  assert.equal(status.hasSelfSigning, true);
  assert.equal(status.hasUserSigning, true);
  const identity = await f.api.getOwnIdentity();
  assert.equal(identity.isVerified(), true);
  identity.free();
  assert.equal(f.signatures.length, 2);
  assert.ok(f.signatures.some(value => value[userId]?.PC));
  assert.deepEqual(await f.api.getSessionBackupPrivateKey(), Uint8Array.from(atob(f.backup.toBase64()), c => c.charCodeAt(0)));
  // Restore an actual Megolm session through the production SDK backup API,
  // then decrypt a message which this fresh PC could not previously read.
  const room = new wasm.RoomId('!qr-history:example.org');
  await f.phone.shareRoomKey(room, [], new wasm.EncryptionSettings());
  const content = JSON.parse(await f.phone.encryptRoomEvent(room, 'm.room.message', JSON.stringify({ msgtype: 'm.text', body: 'history restored automatically' })));
  const exported = JSON.parse(await f.phone.exportRoomKeys(() => true));
  const key = exported.find(value => value.session_id === content.session_id);
  assert.ok(key);
  const event = JSON.stringify({ type: 'm.room.encrypted', sender: userId, event_id: '$history', origin_server_ts: 1, content });
  const settings = new wasm.DecryptionSettings(wasm.TrustRequirement.Untrusted);
  await assert.rejects(f.engine.decryptRoomEvent(event, room, settings));
  const pk = wasm.PkEncryption.fromKey(new wasm.Curve25519PublicKey(f.backup.megolmV1PublicKey.publicKeyBase64));
  const encrypted = pk.encryptString(JSON.stringify(key));
  const boxed = encrypted.toBase64();
  f.backupData.rooms[room.toString()] = { sessions: { [key.session_id]: {
    first_message_index: 0, forwarded_count: 0, is_verified: true,
    session_data: { ephemeral: boxed.ephemeralKey, mac: boxed.mac, ciphertext: boxed.ciphertext },
  } } };
  const restored = await f.api.restoreKeyBackup({});
  assert.equal(restored.imported, 1);
  const clear = await f.engine.decryptRoomEvent(event, room, settings);
  assert.equal(JSON.parse(clear.event).content.body, 'history restored automatically');
  clear.free(); pk.free(); encrypted.free(); boxed.free(); settings.free(); room.free();
});

test('an old or replaced backup is rejected rather than reported as recovered', async t => {
  const f = await fixture(t);
  f.bundle.backup.backup_version = 'old-version';
  await assert.rejects(importQrCachedSecrets(f.client, { userId, deviceId: 'PC' }, f.bundle), /备份已变化/);
  assert.equal(await f.api.getSessionBackupPrivateKey(), null);
});

test('a changed master identity cannot receive trust or device signatures', async t => {
  const f = await fixture(t);
  f.bundle.master_key = Buffer.alloc(32, 42).toString('base64').replaceAll('=', '');
  await assert.rejects(importQrCachedSecrets(f.client, { userId, deviceId: 'PC' }, f.bundle), /加密身份已变化/);
  assert.equal(f.signatures.length, 0);
  assert.equal((await f.engine.crossSigningStatus()).hasSelfSigning, false);
});

test('wrong destination and cancelled imports do not establish trust', async t => {
  const f = await fixture(t);
  await assert.rejects(importQrCachedSecrets(f.client, { userId, deviceId: 'OTHER' }, f.bundle), /不匹配/);
  await assert.rejects(importQrCachedSecrets(f.client, { userId, deviceId: 'PC' }, f.bundle, { isActive: () => false }), /已取消/);
  assert.equal(f.signatures.length, 0);
});

test('a substituted self signing seed fails real Rust import', async t => {
  const f = await fixture(t);
  f.bundle.self_signing_key.private_key = Buffer.alloc(32, 42).toString('base64').replaceAll('=', '');
  await assert.rejects(importQrCachedSecrets(f.client, { userId, deviceId: 'PC' }, f.bundle));
  assert.equal(f.signatures.length, 0);
});
