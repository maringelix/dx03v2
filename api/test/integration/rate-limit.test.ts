import request from 'supertest';
import { afterEach, beforeAll, describe, expect, it } from 'vitest';
import { createPool } from '../../src/db.ts';
import { createTestApp, resetDatabase, silentLogger, testConfig, type TestApp } from './helpers.ts';

const LIMIT = 3;
const opened: TestApp[] = [];

function app(hops: string): TestApp {
  const t = createTestApp({ RATE_LIMIT_WRITE_PER_MINUTE: String(LIMIT), TRUST_PROXY_HOPS: hops });
  opened.push(t);
  return t;
}

beforeAll(async () => {
  const pool = createPool(testConfig().db, silentLogger);
  await resetDatabase(pool);
  await pool.end();
});

afterEach(async () => {
  await Promise.all(opened.splice(0).map((t) => t.close()));
});

// A spoofed leftmost entry per request, followed by the address the trusted proxy (web nginx)
// appended: `$proxy_add_x_forwarded_for` produces exactly this shape.
const viaProxy = (spoofed: number, realClient = '203.0.113.7') => `198.51.100.${spoofed}, ${realClient}`;

describe('write rate limit', () => {
  it('answers 429 with Retry-After once the per-client limit is reached', async () => {
    const t = app('1');
    for (let i = 1; i <= LIMIT; i++) {
      const res = await request(t.app)
        .post('/api/messages')
        .send({ author: 'Ana', text: `n${i}` });
      expect(res.status).toBe(201);
      expect(res.headers.ratelimit).toBeDefined();
    }
    const limited = await request(t.app).post('/api/messages').send({ author: 'Ana', text: 'mais uma' });
    expect(limited.status).toBe(429);
    expect(Number(limited.headers['retry-after'])).toBeGreaterThan(0);
    expect(limited.body.error).toMatchObject({ code: 'rate_limited', requestId: limited.headers['x-request-id'] });
  });

  it('ignores spoofed leftmost X-Forwarded-For entries behind one trusted proxy', async () => {
    const t = app('1');
    const statuses: number[] = [];
    for (let i = 1; i <= LIMIT + 2; i++) {
      const res = await request(t.app)
        .post('/api/messages')
        .set('X-Forwarded-For', viaProxy(i))
        .send({ author: 'Ana', text: `spoof ${i}` });
      statuses.push(res.status);
    }
    expect(statuses).toEqual([201, 201, 201, 429, 429]);

    // A different real client (different address appended by the proxy) has its own budget.
    const other = await request(t.app)
      .post('/api/messages')
      .set('X-Forwarded-For', viaProxy(99, '203.0.113.8'))
      .send({ author: 'Bia', text: 'outra origem' });
    expect(other.status).toBe(201);
  });

  it('reads the client from the comma-only X-Forwarded-For of Application Gateway for Containers', async () => {
    // AGC appends the address it received the request from, comma delimited without a space
    // (docs "Application Gateway for Containers components", checked 2026-10-11).
    const t = app('1');
    const statuses: number[] = [];
    for (let i = 1; i <= LIMIT + 1; i++) {
      const res = await request(t.app)
        .post('/api/messages')
        .set('X-Forwarded-For', `198.51.100.${i},203.0.113.9`)
        .send({ author: 'Ana', text: `agc ${i}` });
      statuses.push(res.status);
    }
    expect(statuses).toEqual([201, 201, 201, 429]);
  });

  it('reads the client from the X-Forwarded-For of the Google Cloud Application Load Balancer', async () => {
    // The global external Application Load Balancer appends `<client-ip>,<load-balancer-ip>` to
    // whatever the client sent, `[<supplied>,]<client-ip>,<lb-ip>`, and the connection comes from a
    // Google Front End (docs "External Application Load Balancer overview", checked 2026-10-11):
    // two trusted hops, TRUST_PROXY_HOPS=2 in dx03v2.
    const t = app('2');
    const statuses: number[] = [];
    for (let i = 1; i <= LIMIT + 1; i++) {
      const res = await request(t.app)
        .post('/api/messages')
        .set('X-Forwarded-For', `198.51.100.${i},203.0.113.9,192.0.2.10`)
        .send({ author: 'Ana', text: `gke ${i}` });
      statuses.push(res.status);
    }
    expect(statuses).toEqual([201, 201, 201, 429]);

    // Another client behind the same load balancer has its own budget.
    const other = await request(t.app)
      .post('/api/messages')
      .set('X-Forwarded-For', '198.51.100.99,203.0.113.8,192.0.2.10')
      .send({ author: 'Bia', text: 'outra origem' });
    expect(other.status).toBe(201);
  });

  it('counts rejected writes too (the limiter runs before validation)', async () => {
    const t = app('1');
    const statuses: number[] = [];
    for (let i = 0; i <= LIMIT; i++) {
      statuses.push((await request(t.app).post('/api/messages').send({ author: '', text: '' })).status);
    }
    expect(statuses).toEqual([400, 400, 400, 429]);
  });

  it('ignores X-Forwarded-For entirely when no proxy is trusted', async () => {
    const t = app('0');
    const statuses: number[] = [];
    for (let i = 1; i <= LIMIT + 1; i++) {
      const res = await request(t.app)
        .post('/api/messages')
        .set('X-Forwarded-For', `198.51.100.${i}`)
        .send({ author: 'Ana', text: `direto ${i}` });
      statuses.push(res.status);
    }
    expect(statuses).toEqual([201, 201, 201, 429]);
  });

  it('does not limit reads', async () => {
    const t = app('1');
    for (let i = 0; i < LIMIT * 3; i++) {
      expect((await request(t.app).get('/api/messages?limit=1')).status).toBe(200);
    }
  });
});
