import type { AddressInfo } from 'node:net';
import express from 'express';
import request from 'supertest';
import { afterEach, describe, expect, it } from 'vitest';
import { createMetrics, createMetricsServer, metricsMiddleware, trackRoute } from '../../src/metrics.ts';

describe('metrics middleware', () => {
  it('labels requests with the route pattern or "unmatched"', async () => {
    const metrics = createMetrics();
    const app = express();
    app.use(metricsMiddleware(metrics));
    const router = express.Router();
    router.get('/', trackRoute, (_req, res) => {
      res.json({});
    });
    router.get('/:id', trackRoute, () => {
      throw new Error('boom');
    });
    app.use('/api/things', router);
    app.use((_req, res) => {
      res.status(404).end();
    });
    app.use((_err: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
      res.status(500).end();
    });

    await request(app).get('/api/things');
    await request(app).get('/api/things/12345');
    await request(app).get('/nowhere/12345');

    const text = await metrics.registry.metrics();
    expect(text).toContain('route="/api/things",status_code="200"');
    expect(text).toContain('route="/api/things/:id",status_code="500"');
    expect(text).toContain('route="unmatched",status_code="404"');
    expect(text).not.toContain('12345');
    // Untraced requests leave no exemplar.
    expect(text).not.toContain('trace_id');
  });
});

describe('metrics server', () => {
  const metrics = createMetrics();
  const server = createMetricsServer(metrics);

  afterEach(() => {
    server.close();
  });

  it('serves GET /metrics only', async () => {
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address() as AddressInfo;
    const base = `http://127.0.0.1:${port}`;

    const ok = await fetch(`${base}/metrics?x=1`);
    expect(ok.status).toBe(200);
    // OpenMetrics: the format that carries exemplars (Prometheus negotiates it).
    expect(ok.headers.get('content-type')).toContain('application/openmetrics-text');
    const body = await ok.text();
    expect(body).toContain('process_cpu_user_seconds_total');
    expect(body).toContain('# HELP http_request_duration_seconds');
    expect(body.trimEnd().endsWith('# EOF')).toBe(true);

    expect((await fetch(`${base}/other`)).status).toBe(404);
    expect((await fetch(`${base}/metrics`, { method: 'POST' })).status).toBe(404);
  });
});
