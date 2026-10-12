import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { ADMIN_TOKEN, createTestApp, resetDatabase, type TestApp } from './helpers.ts';

let t: TestApp;

beforeAll(() => {
  // A high write limit: the rate limiter has its own test file.
  t = createTestApp({ RATE_LIMIT_WRITE_PER_MINUTE: '1000' });
});

afterAll(async () => {
  await t.close();
});

beforeEach(async () => {
  await resetDatabase(t.pool);
});

const post = (body: unknown) =>
  request(t.app)
    .post('/api/messages')
    .send(body as object);

describe('POST /api/messages', () => {
  it('creates a message and returns 201 with Location', async () => {
    const res = await post({ author: '  Ana ', text: ' Primeira mensagem ' });
    expect(res.status).toBe(201);
    expect(res.headers.location).toBe(`/api/messages/${res.body.id}`);
    expect(res.body).toEqual({
      id: expect.any(Number),
      author: 'Ana',
      text: 'Primeira mensagem',
      createdAt: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/),
    });
  });

  it('stores markup exactly as sent (the UI renders text, nothing is HTML-escaped)', async () => {
    const text = '<script>alert("x")</script> & \'aspas\' <b>negrito</b>';
    const created = await post({ author: '<Bob>', text });
    expect(created.body.text).toBe(text);
    const row = await t.pool.query<{ author: string; body: string }>('SELECT author, body FROM messages');
    expect(row.rows[0]).toEqual({ author: '<Bob>', body: text });
    const listed = await request(t.app).get('/api/messages');
    expect(listed.body.items[0].text).toBe(text);
  });

  it.each([
    [{ author: '', text: 'oi' }, /author: must have 1 to 40 characters/],
    [{ author: 'Ana', text: 'x'.repeat(281) }, /text: must have 1 to 280 characters/],
    [{ author: 'Ana', text: 'tab\there' }, /text: must not contain control characters/],
    [{ author: 'Ana', text: 'oi', extra: 1 }, /Unrecognized key/i],
    [{ text: 'oi' }, /author: is required/],
    [['author', 'text'], /body must be a JSON object/],
  ])('rejects %j with 400 validation_error', async (body, message) => {
    const res = await post(body);
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('validation_error');
    expect(res.body.error.message).toMatch(message);
    expect(res.body.error.requestId).toBe(res.headers['x-request-id']);
  });

  it('rejects malformed JSON with 400 invalid_json', async () => {
    const res = await request(t.app)
      .post('/api/messages')
      .set('Content-Type', 'application/json')
      .send('{"author": "Ana", "text": ');
    expect(res.status).toBe(400);
    expect(res.body.error).toMatchObject({ code: 'invalid_json', message: 'Request body is not valid JSON' });
  });

  it('rejects a body over 10 kb with 413', async () => {
    const res = await post({ author: 'Ana', text: 'x'.repeat(11 * 1024) });
    expect(res.status).toBe(413);
    expect(res.body.error.code).toBe('payload_too_large');
  });

  it('rejects a non-JSON content type with 415', async () => {
    const res = await request(t.app).post('/api/messages').set('Content-Type', 'text/plain').send('author=Ana');
    expect(res.status).toBe(415);
    expect(res.body.error.code).toBe('unsupported_media_type');
  });

  it('rejects an empty body: 415 without a JSON content type, 400 with one', async () => {
    const untyped = await request(t.app).post('/api/messages');
    expect(untyped.status).toBe(415);
    const typed = await request(t.app).post('/api/messages').set('Content-Type', 'application/json');
    expect(typed.status).toBe(400);
    expect(typed.body.error.code).toBe('validation_error');
  });
});

describe('GET /api/messages', () => {
  it('lists newest first and honours limit', async () => {
    for (const n of [1, 2, 3]) {
      expect((await post({ author: 'Ana', text: `mensagem ${n}` })).status).toBe(201);
    }
    const all = await request(t.app).get('/api/messages');
    expect(all.status).toBe(200);
    expect(all.body.items.map((m: { text: string }) => m.text)).toEqual(['mensagem 3', 'mensagem 2', 'mensagem 1']);

    const limited = await request(t.app).get('/api/messages?limit=2');
    expect(limited.body.items).toHaveLength(2);
  });

  it.each(['0', '101', 'abc', '2&limit=3'])('rejects limit=%s with 400', async (limit) => {
    const res = await request(t.app).get(`/api/messages?limit=${limit}`);
    expect(res.status).toBe(400);
    expect(res.body.error.message).toMatch(/limit: must be an integer between 1 and 100/);
  });

  it('defaults to 20 items', async () => {
    await t.pool.query("INSERT INTO messages (author, body) SELECT 'bot', 'm' || g FROM generate_series(1, 25) AS g");
    const res = await request(t.app).get('/api/messages');
    expect(res.body.items).toHaveLength(20);
  });
});

describe('DELETE /api/messages/:id', () => {
  it('requires the admin token (401 without or with a wrong one)', async () => {
    const { body } = await post({ author: 'Ana', text: 'apagar' });
    const missing = await request(t.app).delete(`/api/messages/${body.id}`);
    expect(missing.status).toBe(401);
    expect(missing.headers['www-authenticate']).toBe('Bearer realm="dx03v2"');
    const wrong = await request(t.app).delete(`/api/messages/${body.id}`).set('Authorization', 'Bearer nope');
    expect(wrong.status).toBe(401);
    expect((await request(t.app).get('/api/stats')).body).toEqual({ messages: 1 });
  });

  it('deletes with the token (204) and then answers 404', async () => {
    const { body } = await post({ author: 'Ana', text: 'apagar' });
    const auth = `Bearer ${ADMIN_TOKEN}`;
    const deleted = await request(t.app).delete(`/api/messages/${body.id}`).set('Authorization', auth);
    expect(deleted.status).toBe(204);
    expect(deleted.text).toBe('');
    const again = await request(t.app).delete(`/api/messages/${body.id}`).set('Authorization', auth);
    expect(again.status).toBe(404);
    expect(again.body.error.code).toBe('not_found');
  });

  it.each(['abc', '0', '-1', '99999999999'])('rejects id %s with 400', async (id) => {
    const res = await request(t.app).delete(`/api/messages/${id}`).set('Authorization', `Bearer ${ADMIN_TOKEN}`);
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('validation_error');
  });

  it('answers 503 admin_disabled when ADMIN_TOKEN is not set', async () => {
    const noAdmin = createTestApp({ ADMIN_TOKEN: '' });
    try {
      const res = await request(noAdmin.app).delete('/api/messages/1').set('Authorization', `Bearer ${ADMIN_TOKEN}`);
      expect(res.status).toBe(503);
      expect(res.body.error.code).toBe('admin_disabled');
    } finally {
      await noAdmin.close();
    }
  });
});

describe('GET /api/stats and /api/info', () => {
  it('counts messages', async () => {
    expect((await request(t.app).get('/api/stats')).body).toEqual({ messages: 0 });
    await post({ author: 'Ana', text: 'um' });
    expect((await request(t.app).get('/api/stats')).body).toEqual({ messages: 1 });
  });

  it('describes the build without secrets or database details', async () => {
    const res = await request(t.app).get('/api/info');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      name: 'dx03v2-api',
      version: '2.0.0-test',
      commit: '0123456789abcdef0123456789abcdef01234567',
      environment: 'ci',
      uptimeSeconds: expect.any(Number),
    });
    const text = JSON.stringify(res.body);
    expect(text).not.toContain(t.config.db.password);
    expect(text).not.toContain(ADMIN_TOKEN);
  });
});

describe('cross-cutting behaviour', () => {
  it('answers unknown routes with a JSON 404', async () => {
    const res = await request(t.app).get('/api/nope');
    expect(res.status).toBe(404);
    expect(res.headers['content-type']).toMatch(/application\/json/);
    expect(res.body.error).toEqual({ code: 'not_found', message: 'Route not found', requestId: expect.any(String) });
  });

  it('echoes a safe X-Request-Id and replaces an unsafe one', async () => {
    const kept = await request(t.app).get('/api/info').set('X-Request-Id', 'smoke-123');
    expect(kept.headers['x-request-id']).toBe('smoke-123');
    const replaced = await request(t.app).get('/api/nope').set('X-Request-Id', 'bad id with spaces');
    expect(replaced.headers['x-request-id']).toMatch(/^[0-9a-f-]{36}$/);
    expect(replaced.body.error.requestId).toBe(replaced.headers['x-request-id']);
  });

  it('sends API security headers, no HSTS and no X-Powered-By', async () => {
    const res = await request(t.app).get('/api/info');
    expect(res.headers['content-security-policy']).toBe("default-src 'none';frame-ancestors 'none'");
    expect(res.headers['x-content-type-options']).toBe('nosniff');
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.headers['strict-transport-security']).toBeUndefined();
    expect(res.headers['x-powered-by']).toBeUndefined();
    expect(res.headers['access-control-allow-origin']).toBeUndefined();
  });

  it('records route patterns, never raw paths, in the HTTP histogram', async () => {
    const { body } = await post({ author: 'Ana', text: 'métrica' });
    await request(t.app).delete(`/api/messages/${body.id}`).set('Authorization', `Bearer ${ADMIN_TOKEN}`);
    await request(t.app).get('/api/messages/987654');
    await request(t.app).post('/api/messages').set('Content-Type', 'application/json').send('{');
    const text = await t.metrics.registry.metrics();
    expect(text).toContain('method="POST",route="/api/messages",status_code="201"');
    expect(text).toContain('method="DELETE",route="/api/messages/:id",status_code="204"');
    expect(text).toContain('method="POST",route="/api/messages",status_code="400"');
    expect(text).toContain('method="GET",route="unmatched",status_code="404"');
    expect(text).not.toContain('987654');
    expect(text).not.toContain(`/api/messages/${body.id}"`);
  });
});
