const FACES = [
  null,
  { face: '😖', label: 'Not great' },
  { face: '🙁', label: 'Meh' },
  { face: '😐', label: 'Okay' },
  { face: '🙂', label: 'Good' },
  { face: '😍', label: 'Love it' },
];

const CONTROL = /[\x00-\x08\x0B-\x1F\x7F]/g;
const ALL_CONTROL = /[\x00-\x1F\x7F]/g;

function cleanField(value) {
  return value.replace(ALL_CONTROL, '').trim();
}

function cleanIdea(value) {
  return value.replace(/\r\n/g, '\n').replace(CONTROL, '').replace(/\r/g, '').trim();
}

export function validate(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    return { ok: false, error: 'Invalid feedback' };
  }

  const rating = body.rating ?? null;
  if (rating !== null && (!Number.isInteger(rating) || rating < 1 || rating > 5)) {
    return { ok: false, error: 'Invalid rating' };
  }

  if (body.idea != null && typeof body.idea !== 'string') {
    return { ok: false, error: 'Invalid idea' };
  }
  const idea = body.idea == null ? null : cleanIdea(body.idea) || null;
  if (idea !== null && Array.from(idea).length > 2000) {
    return { ok: false, error: 'Idea is too long' };
  }
  if (rating === null && idea === null) {
    return { ok: false, error: 'Rating or idea required' };
  }

  if (body.reply_to != null && typeof body.reply_to !== 'string') {
    return { ok: false, error: 'Invalid reply address' };
  }
  const reply_to = body.reply_to == null ? null : cleanField(body.reply_to) || null;
  if (reply_to !== null && (Array.from(reply_to).length > 200 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(reply_to))) {
    return { ok: false, error: 'Invalid reply address' };
  }

  if (typeof body.version !== 'string') {
    return { ok: false, error: 'Invalid version' };
  }
  const version = cleanField(body.version);
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    return { ok: false, error: 'Invalid version' };
  }

  if (typeof body.macos !== 'string') {
    return { ok: false, error: 'Invalid macOS version' };
  }
  const macos = cleanField(body.macos);
  if (Array.from(macos).length > 40 || !/^[\x20-\x7E]*$/.test(macos)) {
    return { ok: false, error: 'Invalid macOS version' };
  }

  return { ok: true, value: { rating, idea, reply_to, version, macos } };
}

export function formatEmail(value, receivedISO) {
  const { rating, idea, reply_to, version, macos } = value;
  const subject = rating === null
    ? `Buddy feedback · idea · v${version}`
    : `Buddy feedback · ${FACES[rating].face} ${rating}/5${idea ? ' + idea' : ''} · v${version}`;
  const text = [
    `Rating: ${rating === null ? '—' : `${rating}/5 (${FACES[rating].label})`}`,
    idea ? `Idea:\n${idea}` : 'Idea: —',
    `Reply to: ${reply_to ?? '—'}`,
    `Buddy: v${version}`,
    `macOS: ${macos || '—'}`,
    `Received: ${receivedISO}`,
  ].join('\n');
  return { subject, text };
}

// Room for a 2000-character idea in any script, JSON-escaped, plus the other fields.
const MAX_BYTES = 16384;

// The body as text, or null once it's over max bytes: a declared length over the limit
// is refused unread, and a body without one stops being read at the limit.
async function readCapped(request, max) {
  const declared = Number(request.headers.get('content-length'));
  if (declared > max) {
    await request.body?.cancel().catch(() => {});
    return null;
  }
  if (!request.body) return '';
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) { bytes.set(c, at); at += c.byteLength; }
  return new TextDecoder().decode(bytes);
}

function json(status, data) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

async function handle(request, env, path) {
  if (path !== '/feedback') return json(404, { ok: false, error: 'Not found' });
  if (request.method !== 'POST') return json(405, { ok: false, error: 'Method not allowed' });

  let raw;
  try {
    raw = await readCapped(request, MAX_BYTES);
  } catch {
    return json(400, { ok: false, error: 'Invalid body' });
  }
  if (raw === null) return json(413, { ok: false, error: 'Body too large' });

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return json(400, { ok: false, error: 'Invalid JSON' });
  }
  const result = validate(body);
  if (!result.ok) return json(400, { ok: false, error: result.error });

  try {
    const key = request.headers.get('CF-Connecting-IP') || 'unknown';
    const limited = await env.LIMITER.limit({ key });
    if (!limited.success) return json(429, { ok: false, error: 'Too many requests' });

    const { subject, text } = formatEmail(result.value, new Date().toISOString());
    const message = {
      to: env.FEEDBACK_TO,
      from: { email: env.FEEDBACK_FROM, name: 'Buddy feedback' },
      subject,
      text,
    };
    if (result.value.reply_to) message.replyTo = result.value.reply_to;
    await env.EMAIL.send(message);
    return json(200, { ok: true });
  } catch {
    return json(502, { ok: false, error: 'Feedback service unavailable' });
  }
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    let response;
    try {
      response = await handle(request, env, path);
    } catch {
      response = json(502, { ok: false, error: 'Feedback service unavailable' });
    }
    console.log(`${request.method} ${path} ${response.status}`);
    return response;
  },
};
