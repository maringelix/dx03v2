import { once } from 'node:events';
import { connect, type Socket } from 'node:net';
import { setTimeout as sleep } from 'node:timers/promises';
import { beforeAll, describe, expect, it } from 'vitest';
import { createPool } from '../../src/db.ts';
import { startServer } from '../../src/server.ts';
import { resetDatabase, silentLogger, testConfig } from './helpers.ts';

function readAll(socket: Socket): Promise<string> {
  return new Promise((resolve, reject) => {
    let data = '';
    socket.setEncoding('utf8');
    socket.on('data', (chunk: string) => {
      data += chunk;
    });
    socket.once('end', () => {
      resolve(data);
    });
    socket.once('error', reject);
  });
}

beforeAll(async () => {
  const pool = createPool(testConfig().db, silentLogger);
  await resetDatabase(pool);
  await pool.end();
});

describe('startServer', () => {
  it('serves the API and /metrics on separate ports and shuts down gracefully', async () => {
    const running = await startServer({ ...testConfig(), port: 0, metricsPort: 0 }, silentLogger);
    const base = `http://127.0.0.1:${running.port}`;

    expect((await fetch(`${base}/healthz`)).status).toBe(200);
    expect((await fetch(`${base}/readyz`)).status).toBe(200);
    expect((await fetch(`${base}/metrics`)).status).toBe(404);
    const metrics = await (await fetch(`http://127.0.0.1:${running.metricsPort}/metrics`)).text();
    expect(metrics).toContain('http_request_duration_seconds_count{method="GET",route="/healthz",status_code="200"} 1');

    // An in-flight request: headers and part of the body arrive before the shutdown starts.
    const body = JSON.stringify({ author: 'Ana', text: 'durante o desligamento' });
    const socket = connect(running.port, '127.0.0.1');
    await once(socket, 'connect');
    const response = readAll(socket);
    socket.write(
      'POST /api/messages HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\n' +
        `Content-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body.slice(0, 10)}`,
    );
    await sleep(200);

    const stopping = running.shutdown('test');
    expect(running.state.shuttingDown).toBe(true);
    expect(running.shutdown('again')).toBe(stopping);
    socket.write(body.slice(10));

    expect(await response).toMatch(/^HTTP\/1\.1 201 Created\r\n/);
    await stopping;
    expect(running.pool.ended).toBe(true);
    await expect(fetch(`${base}/healthz`)).rejects.toThrow();

    const check = createPool(testConfig().db, silentLogger);
    try {
      const saved = await check.query<{ body: string }>('SELECT body FROM messages');
      expect(saved.rows.map((row) => row.body)).toEqual(['durante o desligamento']);
    } finally {
      await check.end();
    }
  });
});
