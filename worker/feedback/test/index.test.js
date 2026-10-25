import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { validate, formatEmail } from '../src/index.js';

const endpoint = 'https://example.workers.dev/feedback';
const received = '2026-10-25T12:34:56.000Z';

function fakeEnv(overrides = {}) {
  const sent = [];
  const keys = [];
  const env = {
    EMAIL: { send: async message => { sent.push(message); return { messageId: 'x' }; } },
    LIMITER: { limit: async ({ key }) => { keys.push(key); return { success: true }; } },
    FEEDBACK_TO: 'to@example.com',
    FEEDBACK_FROM: 'from@example.com',
    ...overrides,
  };
  return { env, sent, keys };
}

function payload(changes = {}) {
  return { rating: 4, idea: 'Make Buddy wave', reply_to: null, version: '1.7.0', macos: '15.1', ...changes };
}

async function post(body, env, headers = {}) {
  const request = new Request(endpoint, { method: 'POST', headers, body });
  return worker.fetch(request, env);
}

test('rating only has the correct face and subject', () => {
  const result = validate(payload({ rating: 5, idea: null }));
  assert.equal(result.ok, true);
  assert.equal(formatEmail(result.value, received).subject, 'Buddy feedback · 😍 5/5 · v1.7.0');
});

test('idea only has the idea subject', () => {
  const result = validate(payload({ rating: null }));
  assert.equal(result.ok, true);
  assert.equal(formatEmail(result.value, received).subject, 'Buddy feedback · idea · v1.7.0');
});

test('rating and idea have the combined subject and fixed body order', () => {
  const result = validate(payload({ idea: 'First line\nSecond line' }));
  assert.equal(result.ok, true);
  assert.deepEqual(formatEmail(result.value, received), {
    subject: 'Buddy feedback · 🙂 4/5 + idea · v1.7.0',
    text: `Rating: 4/5 (Good)\nIdea:\nFirst line\nSecond line\nReply to: —\nBuddy: v1.7.0\nmacOS: 15.1\nReceived: ${received}`,
  });
});

test('all rating labels and faces match the plan', () => {
  const expected = [
    ['😖', 'Not great'], ['🙁', 'Meh'], ['😐', 'Okay'], ['🙂', 'Good'], ['😍', 'Love it'],
  ];
  expected.forEach(([face, label], index) => {
    const rating = index + 1;
    const result = formatEmail(validate(payload({ rating, idea: null })).value, received);
    assert.equal(result.subject, `Buddy feedback · ${face} ${rating}/5 · v1.7.0`);
    assert.match(result.text, new RegExp(`^Rating: ${rating}/5 \\(${label}\\)`));
  });
});

test('reply address and secret bindings are passed to Email Service', async () => {
  const { env, sent, keys } = fakeEnv();
  const response = await post(JSON.stringify(payload({ reply_to: 'person@example.com' })), env, { 'CF-Connecting-IP': '192.0.2.1' });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].replyTo, 'person@example.com');
  assert.deepEqual(sent[0].from, { email: 'from@example.com', name: 'Buddy feedback' });
  assert.equal(sent[0].to, 'to@example.com');
  assert.deepEqual(keys, ['192.0.2.1']);
});

test('missing IP uses the unknown limiter key', async () => {
  const { env, keys } = fakeEnv();
  await post(JSON.stringify(payload()), env);
  assert.deepEqual(keys, ['unknown']);
});

for (const [name, changes] of [
  ['neither rating nor idea', { rating: null, idea: null }],
  ['rating 6', { rating: 6 }],
  ['fractional rating', { rating: 2.5 }],
  ['idea over 2000 characters', { idea: 'a'.repeat(2001) }],
  ['bad email', { reply_to: 'not-an-email' }],
  ['invalid version', { version: '1.7' }],
  ['macOS over 40 characters', { macos: 'a'.repeat(41) }],
]) {
  test(`${name} returns 400`, async () => {
    const { env, sent } = fakeEnv();
    const response = await post(JSON.stringify(payload(changes)), env);
    assert.equal(response.status, 400);
    assert.equal((await response.json()).ok, false);
    assert.equal(sent.length, 0);
  });
}

test('raw UTF-8 body over 16384 bytes returns 413', async () => {
  const { env, sent } = fakeEnv();
  const response = await post(JSON.stringify(payload({ idea: 'x'.repeat(1990), reply_to: null, macos: '15.1', pad: '😀'.repeat(4000) })), env);
  assert.equal(response.status, 413);
  assert.equal(sent.length, 0);
});

test('a full 2000-character idea in any script fits', async () => {
  for (const ch of ['😀', '漢', '"']) {
    const { env, sent } = fakeEnv();
    const response = await post(JSON.stringify(payload({ idea: ch.repeat(2000) })), env);
    assert.equal(response.status, 200, ch);
    assert.equal(sent.length, 1, ch);
  }
});

test('a declared length over the limit is refused without reading the body', async () => {
  const { env, sent } = fakeEnv();
  let pulled = 0;
  const body = new ReadableStream({ pull(c) { pulled += 1; c.enqueue(new TextEncoder().encode('x'.repeat(1024))); } });
  const request = new Request(endpoint, { method: 'POST', body, duplex: 'half', headers: { 'content-length': '999999' } });
  const response = await worker.fetch(request, env);
  assert.equal(response.status, 413);
  assert.ok(pulled <= 1, `read ${pulled} chunks`);
  assert.equal(sent.length, 0);
});

test('an endless body without a length is cut off at the limit', async () => {
  const { env, sent } = fakeEnv();
  let pulled = 0;
  const body = new ReadableStream({ pull(c) { pulled += 1; c.enqueue(new TextEncoder().encode('x'.repeat(1024))); } });
  const request = new Request(endpoint, { method: 'POST', body, duplex: 'half' });
  const response = await worker.fetch(request, env);
  assert.equal(response.status, 413);
  assert.ok(pulled <= 20, `read ${pulled} chunks`);
  assert.equal(sent.length, 0);
});

test('invalid JSON returns 400', async () => {
  const { env } = fakeEnv();
  assert.equal((await post('{', env)).status, 400);
});

test('GET /feedback returns 405 and POST /other returns 404', async () => {
  const { env } = fakeEnv();
  assert.equal((await worker.fetch(new Request(endpoint), env)).status, 405);
  assert.equal((await worker.fetch(new Request('https://example.workers.dev/other', { method: 'POST' }), env)).status, 404);
});

test('limiter rejection returns 429 without sending', async () => {
  const { env, sent } = fakeEnv({ LIMITER: { limit: async () => ({ success: false }) } });
  assert.equal((await post(JSON.stringify(payload()), env)).status, 429);
  assert.equal(sent.length, 0);
});

test('email failure returns 502', async () => {
  const { env } = fakeEnv({ EMAIL: { send: async () => { throw new Error('failed'); } } });
  assert.equal((await post(JSON.stringify(payload()), env)).status, 502);
});

test('control characters are stripped while idea newlines and tabs survive', () => {
  const result = validate(payload({ idea: ' \u0000A\r\nB\u0007\tC\rD ', reply_to: '\u0000person@example.com\u0007', macos: '15.1\u0000' }));
  assert.equal(result.ok, true);
  assert.equal(result.value.idea, 'A\nB\tCD');
  assert.equal(result.value.reply_to, 'person@example.com');
  assert.equal(result.value.macos, '15.1');
});

test('one content-free log line is written per request', async () => {
  const { env } = fakeEnv();
  const lines = [];
  const previous = console.log;
  console.log = (...args) => lines.push(args.join(' '));
  try {
    await post(JSON.stringify(payload({ idea: 'private marker' })), env);
    assert.deepEqual(lines, ['POST /feedback 200']);
  } finally {
    console.log = previous;
  }
});
