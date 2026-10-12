import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createPool } from '../../src/db.ts';
import { createTestApp, resetDatabase, silentLogger, TcpProxy, testConfig, type TestApp } from './helpers.ts';

describe('probes against a reachable database', () => {
  let t: TestApp;

  beforeAll(async () => {
    t = createTestApp();
    await resetDatabase(t.pool);
  });

  afterAll(async () => {
    await t.close();
  });

  it('GET /healthz is 200 without touching the database', async () => {
    const res = await request(t.app).get('/healthz');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
  });

  it('GET /readyz is 200 when SELECT 1 succeeds', async () => {
    const res = await request(t.app).get('/readyz');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ready' });
  });

  it('GET /readyz is 503 while shutting down', async () => {
    t.state.shuttingDown = true;
    try {
      const res = await request(t.app).get('/readyz');
      expect(res.status).toBe(503);
      expect(res.body).toEqual({ status: 'shutting_down' });
      expect((await request(t.app).get('/healthz')).status).toBe(200);
    } finally {
      t.state.shuttingDown = false;
    }
  });
});

describe('database outage and recovery (no restart, no "init once" flag)', () => {
  const real = () => testConfig().db;
  let proxy: TcpProxy;
  let port: number;
  let t: TestApp;

  beforeAll(async () => {
    const pool = createPool(real(), silentLogger);
    await resetDatabase(pool);
    await pool.end();
    proxy = new TcpProxy(real().host, real().port);
    port = await proxy.start();
    t = createTestApp({}, (config) => ({ ...config, db: { ...config.db, host: '127.0.0.1', port } }));
  });

  afterAll(async () => {
    await t?.close();
    await proxy?.stop();
  });

  it('follows the database: ready, then 503 during the outage, then ready again', async () => {
    expect((await request(t.app).get('/readyz')).status).toBe(200);
    expect((await request(t.app).post('/api/messages').send({ author: 'Ana', text: 'antes' })).status).toBe(201);

    await proxy.stop();
    const down = await request(t.app).get('/readyz');
    expect(down.status).toBe(503);
    expect(down.body).toEqual({ status: 'db_unavailable' });
    expect((await request(t.app).get('/healthz')).status).toBe(200);
    const list = await request(t.app).get('/api/messages');
    expect(list.status).toBe(503);
    expect(list.body.error.code).toBe('db_unavailable');

    await proxy.start(port);
    expect((await request(t.app).get('/readyz')).status).toBe(200);
    const after = await request(t.app).get('/api/messages');
    expect(after.status).toBe(200);
    expect(after.body.items.map((m: { text: string }) => m.text)).toEqual(['antes']);
  });
});
