import { sameLoginHomeserver } from './login-config.js';

// Custom app-to-app flow over the existing encrypted rendezvous transport.
// No OAuth device grant, authorization code, or copied phone access token.
export async function createPasswordQrFlow(rendezvous, client, onFailure, signal, onConnected) {
  const wasm = await import('@matrix-org/matrix-sdk-crypto-wasm');
  await wasm.initAsync(); signal.throwIfAborted();
  const session = new rendezvous.MSC4108RendezvousSession({ client, onFailure });
  const channel = new rendezvous.MSC4108SecureChannel(session, undefined, onFailure);
  signal.addEventListener('abort', () => {
    session.onFailure = undefined; channel.onFailure = undefined;
    channel.cancel(rendezvous.MSC4108FailureReason.UserCancelled).catch(() => {});
  }, { once: true });
  try {
    await session.send(''); signal.throwIfAborted();
    const code = await channel.generateCode(wasm.QrCodeIntent.Login);
    code[7] = 4; // Distinct from standard MSC4108 login (mode 3).
    return {
      code, channel, close: () => channel.close(),
      async connect() { await channel.connect(); onConnected?.(); },
    };
  } catch (error) {
    await channel.close().catch(() => {});
    throw error;
  }
}

function receiveFailure(payload) {
  if (payload?.type === 'm.login.failure') {
    throw Object.assign(new Error('扫码登录未完成'), { code: payload.reason });
  }
  return payload;
}

export async function completePasswordQrLogin(context, { signal, onStage }) {
  const { flow, baseUrl, createClient, resolve } = context;
  const channel = flow.channel;
  let loginClient; let tokens; let requestedDeviceId; let finished = false;
  try {
    await flow.connect(); signal.throwIfAborted();
    onStage('login');
    const hello = receiveFailure(await channel.secureReceive());
    if (hello?.type !== 'org.mxchat.login.protocols' ||
        !hello.protocols?.includes('org.mxchat.password.v1') ||
        typeof hello.user_id !== 'string' || !hello.user_id.startsWith('@') ||
        typeof hello.homeserver !== 'string') throw new Error('手机端不支持账号扫码登录');
    const userId = hello.user_id;
    const domain = userId.slice(userId.indexOf(':') + 1);
    if (userId.indexOf(':') < 2 || domain !== hello.homeserver ||
        !sameLoginHomeserver(await resolve(hello.homeserver), baseUrl)) throw new Error('手机账号的服务器与填写的服务器不一致，请取消后重新填写');
    signal.throwIfAborted();
    const deviceId = requestedDeviceId = `MXCHAT_${crypto.randomUUID().replaceAll('-', '').slice(0, 20)}`;
    await channel.secureSend({ type: 'org.mxchat.login.request', protocol: 'org.mxchat.password.v1', device_id: deviceId,
      ...(hello['org.mxchat.cached_secrets'] === 1 ? { 'org.mxchat.cached_secrets': 1 } : {}) });
    let credentials = receiveFailure(await channel.secureReceive());
    if (credentials?.type !== 'org.mxchat.login.credentials' || credentials.user_id !== userId ||
        typeof credentials.password !== 'string' || !credentials.password || credentials.password.length > 16384) throw new Error('手机没有提供有效的登录凭据');
    signal.throwIfAborted();
    loginClient = createClient({ baseUrl, localTimeoutMs: 30000 });
    try {
      tokens = await loginClient.login('m.login.password', {
        identifier: { type: 'm.id.user', user: userId }, password: credentials.password,
        device_id: deviceId, initial_device_display_name: 'mxchat Desktop',
      });
    } catch (error) {
      throw Object.assign(new Error('服务器未能完成账号登录'), {
        code: ({ M_FORBIDDEN: 'password_invalid', M_LIMIT_EXCEEDED: 'rate_limited', M_USER_DEACTIVATED: 'account_disabled', M_UNRECOGNIZED: 'password_unsupported' })[error.errcode] || 'login_failed',
      });
    } finally {
      credentials.password = ''; credentials = null;
    }
    signal.throwIfAborted();
    if (!tokens?.access_token || tokens.user_id !== userId || tokens.device_id !== deviceId) throw new Error('登录账号或设备 ID 不匹配');
    const identity = await loginClient.whoami();
    if (identity.user_id !== userId || identity.device_id !== deviceId) throw new Error('登录账号或设备 ID 不匹配');
    signal.throwIfAborted();
    await channel.secureSend({ type: 'm.login.success', user_id: userId, device_id: deviceId });
    onStage('keys');
    const secrets = receiveFailure(await channel.secureReceive());
    signal.throwIfAborted();
    if (secrets?.type !== 'm.login.secrets') throw new Error('手机没有提供有效的密钥信息');
    const handoff = secrets['org.mxchat.device_verification'];
    let shared;
    const cached = secrets['org.mxchat.cached_secrets'];
    if (hello['org.mxchat.cached_secrets'] === 1) {
      if (!cached || cached.version !== 1 || cached.user_id !== userId || cached.device_id !== deviceId) throw new Error('手机共享密钥与当前登录设备不匹配');
      shared = { qrBootstrap: cached };
    } else if (handoff) {
      if (handoff.user_id !== userId || typeof handoff.device_id !== 'string' ||
          !handoff.device_id || handoff.device_id.length > 255 || handoff.device_id === deviceId) throw new Error('手机设备验证信息与当前账号不匹配');
      shared = { deviceVerification: { userId, deviceId: handoff.device_id } };
    } else {
      if (!secrets.cross_signing) throw new Error('手机没有提供有效的解密密钥');
      shared = { cross_signing: secrets.cross_signing, ...(secrets.backup ? { backup: secrets.backup } : {}) };
    }
    finished = true;
    return { session: { homeserver: baseUrl, accessToken: tokens.access_token, userId, deviceId }, secrets: shared };
  } catch (error) {
    // Never propagate a server exception that could include a credential body.
    const code = error.errcode === 'M_FORBIDDEN' ? 'password_invalid' : error.code;
    await channel.secureSend({ type: 'm.login.failure', reason: code || 'network_error' }).catch(() => {});
    throw Object.assign(new Error(error.errcode ? '服务器未能完成账号登录' : error.message), code ? { code } : {});
  } finally {
    // A cancelled/failed handoff must not leave an orphaned PC login behind.
    if (tokens?.access_token && !finished) {
      // Revoke only a token confirmed to belong to our new PC device. A bad
      // server response or mismatched whoami must not log out another device.
      try {
        const identity = await loginClient.whoami();
        if (identity.user_id === tokens.user_id && identity.device_id === requestedDeviceId &&
            tokens.device_id === requestedDeviceId) await loginClient.logout();
      } catch { /* Device management can revoke an orphan if the server is unavailable. */ }
    }
  }
}
