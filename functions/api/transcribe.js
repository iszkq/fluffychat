// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const MAX_AUDIO_BYTES = 25 * 1024 * 1024;
const AIHUBMIX_TRANSCRIPTION_URL =
  'https://api.inferera.com/v1/audio/transcriptions';

const jsonResponse = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });

export async function onRequestPost(context) {
  if (!context.env.AIHUBMIX_API_KEY) {
    return jsonResponse({ error: 'Transcription service is not configured.' }, 503);
  }

  let incoming;
  try {
    incoming = await context.request.formData();
  } catch (_) {
    return jsonResponse({ error: 'Expected a multipart form upload.' }, 400);
  }

  const audio = incoming.get('file');
  if (!(audio instanceof File)) {
    return jsonResponse({ error: 'Missing audio file.' }, 400);
  }
  if (audio.size === 0 || audio.size > MAX_AUDIO_BYTES) {
    return jsonResponse({ error: 'Audio must be between 1 byte and 25 MB.' }, 413);
  }

  const upstreamBody = new FormData();
  upstreamBody.set('file', audio, audio.name || 'voice-message.m4a');
  upstreamBody.set('model', 'whisper-large-v3-turbo');
  upstreamBody.set('response_format', 'json');
  upstreamBody.set('temperature', '0.2');

  const language = incoming.get('language');
  if (typeof language === 'string' && /^[a-z]{2}$/.test(language)) {
    upstreamBody.set('language', language);
  }

  let upstream;
  try {
    upstream = await fetch(AIHUBMIX_TRANSCRIPTION_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${context.env.AIHUBMIX_API_KEY}`,
      },
      body: upstreamBody,
    });
  } catch (_) {
    return jsonResponse({ error: 'Unable to reach the transcription provider.' }, 502);
  }

  return new Response(upstream.body, {
    status: upstream.status,
    headers: {
      'content-type': upstream.headers.get('content-type') || 'application/json',
      'cache-control': 'no-store',
    },
  });
}

export function onRequest(context) {
  return jsonResponse({ error: 'Method not allowed.' }, 405);
}
