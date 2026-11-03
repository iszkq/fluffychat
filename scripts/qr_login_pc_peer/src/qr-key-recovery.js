// This adapter is deliberately limited to the pinned matrix-js-sdk 45.0.0.
// Its public bundle importer requires a master seed, while the Rust engine
// supports importing the self/user signing seeds already cached by FluffyChat.
// QR consent authenticates the master fingerprint; never reset the identity.
function keyBytes(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]{43}=?$/.test(value)) throw new Error('手机提供的加密密钥格式无效');
  const bytes = Uint8Array.from(atob(value), c => c.charCodeAt(0));
  if (bytes.length !== 32) throw new Error('手机提供的加密密钥长度无效');
  return bytes;
}
function publicKey(json, userId, usage) {
  const key = typeof json === 'string' ? JSON.parse(json) : json;
  const values = Object.values(key?.keys || {});
  if (key?.user_id !== userId || !key?.usage?.includes(usage) || values.length !== 1) throw new Error('服务器加密身份无效');
  return values[0];
}
export function clearQrCachedSecrets(bundle) {
  if (!bundle) return;
  for (const name of ['self_signing_key', 'user_signing_key']) if (bundle[name]) bundle[name].private_key = '';
  if (bundle.backup) bundle.backup.key = '';
}
export async function importQrCachedSecrets(client, session, bundle, { isActive = () => true } = {}) {
  if (bundle?.version !== 1 || bundle.user_id !== session.userId || bundle.device_id !== session.deviceId) throw new Error('扫码密钥与当前账号或设备不匹配');
  const api = client.getCrypto();
  const engine = api?.olmMachine;
  if (!engine?.importCrossSigningKeys || !api.getOwnIdentity) throw new Error('电脑加密引擎不支持自动恢复，请更新电脑端');
  const assertActive = () => { if (!isActive()) throw new Error('扫码密钥恢复已取消'); };
  assertActive();
  const seeds = [bundle.self_signing_key, bundle.user_signing_key];
  for (const seed of seeds) keyBytes(seed?.private_key).fill(0);
  keyBytes(bundle.master_key).fill(0);
  // Keys may be downloaded just after PREPARED. Only wait for this identity;
  // a different master is a hard failure, never a reason to create a new one.
  let identity;
  for (let attempt = 0; attempt < 20; attempt++) {
    assertActive();
    identity = await api.getOwnIdentity();
    if (identity) break;
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  if (!identity) throw new Error('服务器加密身份尚未同步，请稍后重新扫码');
  try {
    if (publicKey(identity.masterKey, session.userId, 'master') !== bundle.master_key ||
        publicKey(identity.selfSigningKey, session.userId, 'self_signing') !== seeds[0].public_key ||
        publicKey(identity.userSigningKey, session.userId, 'user_signing') !== seeds[1].public_key) throw new Error('账号加密身份已变化，请重新扫码');
    assertActive();
    const status = await engine.importCrossSigningKeys(undefined, seeds[0].private_key, seeds[1].private_key);
    if (!status.hasSelfSigning || !status.hasUserSigning) throw new Error('手机共享的签名密钥无法导入');
    // Trust only the exact identity authenticated by this QR channel, then
    // cross-sign this independent PC device using the imported self-signing key.
    assertActive();
    const signature = await identity.verify();
    assertActive();
    const response = await client.uploadKeySignatures(JSON.parse(signature.body));
    if (Object.keys(response?.failures || {}).length) throw new Error('服务器未能保存电脑设备签名，请重新扫码');
    assertActive();
    await api.crossSignDevice(session.deviceId);
    if (bundle.backup) {
      const bytes = keyBytes(bundle.backup.key);
      try {
        if (typeof bundle.backup.backup_version !== 'string' || !bundle.backup.backup_version) throw new Error('手机备份版本无效');
        const wasm = await import('@matrix-org/matrix-sdk-crypto-wasm');
        const backupKey = wasm.BackupDecryptionKey.fromBase64(bundle.backup.key);
        try {
          const info = await api.getKeyBackupInfo();
          const publicKey = backupKey.megolmV1PublicKey;
          try {
            if (info?.version !== bundle.backup.backup_version || info?.algorithm !== publicKey.algorithm ||
                info?.auth_data?.public_key !== publicKey.publicKeyBase64) throw new Error('历史备份已变化或密钥不匹配，请重新扫码');
          } finally { publicKey.free(); }
        } finally { backupKey.free(); }
        assertActive();
        await api.storeSessionBackupPrivateKey(bytes, bundle.backup.backup_version);
      } finally { bytes.fill(0); }
    }
  } finally { identity.free(); }
}
