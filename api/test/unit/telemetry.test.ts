import { Writable } from 'node:stream';
import { SpanKind, SpanStatusCode, trace } from '@opentelemetry/api';
import { InMemorySpanExporter, SimpleSpanProcessor, type SpanProcessor } from '@opentelemetry/sdk-trace-node';
import express from 'express';
import type { Pool, QueryResult } from 'pg';
import request from 'supertest';
import { afterEach, describe, expect, it } from 'vitest';
import { createLogger } from '../../src/logger.ts';
import { createMetrics, metricsMiddleware, trackRoute } from '../../src/metrics.ts';
import {
  activeSpanContext,
  instrumentPool,
  startTelemetry,
  tracingMiddleware,
  type Telemetry,
} from '../../src/telemetry.ts';

const TRACE_ID = '4bf92f3577b34da6a3ce929d0e0e4736';
const PARENT_ID = '00f067aa0ba902b7';

let telemetry: Telemetry | undefined;
let exporter: InMemorySpanExporter;

function startInMemory(): Telemetry {
  exporter = new InMemorySpanExporter();
  telemetry = startTelemetry({
    endpoint: undefined,
    version: '2.0.0-test',
    appEnv: 'ci',
    gitSha: 'abc1234',
    spanProcessor: new SimpleSpanProcessor(exporter),
  });
  return telemetry;
}

afterEach(async () => {
  await telemetry?.shutdown();
  telemetry = undefined;
});

/** A fake pool: query() resolves with one row, or rejects for statements that contain "fail". */
function fakePool(): Pool {
  return {
    query: (text: string): Promise<QueryResult> =>
      text.includes('fail')
        ? Promise.reject(Object.assign(new Error('relation does not exist'), { code: '42P01' }))
        : Promise.resolve({ rows: [{ one: 1 }], rowCount: 1, command: 'SELECT', oid: 0, fields: [] }),
  } as unknown as Pool;
}

function appWith(pool: Pool) {
  const app = express();
  app.use(tracingMiddleware());
  const router = express.Router();
  router.get('/things/:id', trackRoute, async (_req, res) => {
    await pool.query('SELECT 1 AS one WHERE $1 = $1', ['x']);
    res.json({ ok: true });
  });
  router.get('/broken', trackRoute, async (_req, res) => {
    try {
      await pool.query('SELECT fail FROM nowhere');
    } catch {
      res.status(500).json({ error: 'internal' });
    }
  });
  app.use('/api', router);
  app.get('/healthz', (_req, res) => {
    res.json({ status: 'ok' });
  });
  return app;
}

describe('startTelemetry', () => {
  it('stays off without an endpoint', async () => {
    const off = startTelemetry({ endpoint: undefined, version: '2.0.0', appEnv: 'ci', gitSha: 'x' });
    expect(off.enabled).toBe(false);
    await off.shutdown();
  });

  it('records spans for the OTLP/HTTP exporter when an endpoint is given', () => {
    telemetry = startTelemetry({ endpoint: 'http://127.0.0.1:9', version: '2.0.0', appEnv: 'ci', gitSha: 'x' });
    expect(telemetry.enabled).toBe(true);
    // Not ended: nothing is exported to the closed port on shutdown.
    expect(trace.getTracer('probe').startSpan('x').isRecording()).toBe(true);
  });

  it('reports a failed flush on shutdown instead of rejecting', async () => {
    const errors: unknown[] = [];
    const failing: SpanProcessor = {
      onStart: () => undefined,
      onEnd: () => undefined,
      forceFlush: () => Promise.resolve(),
      shutdown: () => Promise.reject(new Error('collector down')),
    };
    const running = startTelemetry({
      endpoint: undefined,
      version: '2.0.0',
      appEnv: 'ci',
      gitSha: 'x',
      spanProcessor: failing,
      onShutdownError: (err) => errors.push(err),
    });
    await expect(running.shutdown()).resolves.toBeUndefined();
    expect(errors).toHaveLength(1);
    expect(String(errors[0])).toContain('collector down');
  });

  it('shuts down once and unregisters the provider', async () => {
    const running = startInMemory();
    const first = running.shutdown();
    expect(running.shutdown()).toBe(first);
    await first;
    telemetry = undefined;
    expect(trace.getTracer('probe').startSpan('x').isRecording()).toBe(false);
  });
});

describe('tracingMiddleware and instrumentPool', () => {
  it('records a SERVER span named after the route and a CLIENT span per query', async () => {
    startInMemory();
    const pool = instrumentPool(fakePool(), { host: 'db', port: 5432, database: 'dx03v2' });
    await request(appWith(pool)).get('/api/things/12345').expect(200);

    const spans = exporter.getFinishedSpans();
    const server = spans.find((s) => s.kind === SpanKind.SERVER);
    const client = spans.find((s) => s.kind === SpanKind.CLIENT);
    expect(server?.name).toBe('GET /api/things/:id');
    expect(server?.attributes).toMatchObject({
      'http.request.method': 'GET',
      'http.route': '/api/things/:id',
      'http.response.status_code': 200,
      'url.path': '/api/things/12345',
    });
    expect(server?.status.code).toBe(SpanStatusCode.UNSET);
    expect(server?.resource.attributes).toMatchObject({
      'service.name': 'dx03v2-api',
      'service.version': '2.0.0-test',
    });
    expect(client?.name).toBe('SELECT dx03v2');
    expect(client?.attributes).toMatchObject({
      'db.system.name': 'postgresql',
      'db.namespace': 'dx03v2',
      'db.operation.name': 'SELECT',
      'db.query.text': 'SELECT 1 AS one WHERE $1 = $1',
      'server.address': 'db',
      'server.port': 5432,
      'db.response.returned_rows': 1,
    });
    expect(JSON.stringify(client?.attributes)).not.toContain('"x"');
    expect(client?.spanContext().traceId).toBe(server?.spanContext().traceId);
    expect(client?.parentSpanContext?.spanId).toBe(server?.spanContext().spanId);
  });

  it('continues an incoming W3C trace', async () => {
    startInMemory();
    await request(appWith(fakePool()))
      .get('/api/things/1')
      .set('traceparent', `00-${TRACE_ID}-${PARENT_ID}-01`)
      .expect(200);
    const server = exporter.getFinishedSpans().find((s) => s.kind === SpanKind.SERVER);
    expect(server?.spanContext().traceId).toBe(TRACE_ID);
    expect(server?.parentSpanContext?.spanId).toBe(PARENT_ID);
  });

  it('marks failed queries and 5xx responses as errors', async () => {
    startInMemory();
    const pool = instrumentPool(fakePool(), { host: 'db', port: 5432, database: 'dx03v2' });
    await request(appWith(pool)).get('/api/broken').expect(500);
    const spans = exporter.getFinishedSpans();
    const server = spans.find((s) => s.kind === SpanKind.SERVER);
    const client = spans.find((s) => s.kind === SpanKind.CLIENT);
    expect(server?.status.code).toBe(SpanStatusCode.ERROR);
    expect(server?.attributes['error.type']).toBe('500');
    expect(client?.status).toMatchObject({ code: SpanStatusCode.ERROR, message: 'relation does not exist' });
    expect(client?.attributes['error.type']).toBe('42P01');
  });

  it('never traces the Kubernetes probes, nor queries outside a request', async () => {
    startInMemory();
    const pool = instrumentPool(fakePool(), { host: 'db', port: 5432, database: 'dx03v2' });
    await request(appWith(pool)).get('/healthz').expect(200);
    await pool.query('SELECT 1');
    expect(exporter.getFinishedSpans()).toHaveLength(0);
  });

  it('names unmatched requests after the method only', async () => {
    startInMemory();
    await request(appWith(fakePool())).get('/nowhere/12345').expect(404);
    const server = exporter.getFinishedSpans().find((s) => s.kind === SpanKind.SERVER);
    expect(server?.name).toBe('GET');
    expect(server?.attributes['http.route']).toBeUndefined();
  });

  it('is a no-op without a provider', async () => {
    const app = express();
    app.use(tracingMiddleware());
    app.get('/api/span', (_req, res) => {
      res.json({ traced: activeSpanContext() !== undefined });
    });
    const response = await request(app).get('/api/span').set('traceparent', `00-${TRACE_ID}-${PARENT_ID}-01`);
    expect(response.body).toEqual({ traced: false });
  });
});

describe('trace context in logs and metrics', () => {
  it('adds trace_id and span_id to the log lines of a traced request', async () => {
    startInMemory();
    const lines: string[] = [];
    const logger = createLogger(
      { level: 'info', appEnv: 'ci', version: '2.0.0', gitSha: 'abc' },
      new Writable({
        write(chunk: Buffer, _encoding, callback) {
          lines.push(chunk.toString('utf8'));
          callback();
        },
      }),
    );
    const app = express();
    app.use(tracingMiddleware());
    app.get('/api/log', (_req, res) => {
      logger.info('inside');
      res.json({});
    });
    await request(app).get('/api/log').set('traceparent', `00-${TRACE_ID}-${PARENT_ID}-01`).expect(200);
    logger.info('outside');
    const [inside, outside] = lines.map((line) => JSON.parse(line) as Record<string, unknown>);
    expect(inside).toMatchObject({ msg: 'inside', trace_id: TRACE_ID });
    expect(inside?.span_id).toMatch(/^[0-9a-f]{16}$/);
    expect(outside).not.toHaveProperty('trace_id');
  });

  it('keeps the trace id of a request as the exemplar of its histogram sample', async () => {
    startInMemory();
    const metrics = createMetrics();
    const app = express();
    app.use(tracingMiddleware());
    app.use(metricsMiddleware(metrics));
    const router = express.Router();
    router.get('/things', trackRoute, (_req, res) => {
      res.json({});
    });
    app.use('/api', router);
    await request(app).get('/api/things').set('traceparent', `00-${TRACE_ID}-${PARENT_ID}-01`).expect(200);
    const text = await metrics.registry.metrics();
    expect(text).toMatch(
      new RegExp(
        `http_request_duration_seconds_bucket\\{[^}]*route="/api/things"[^}]*\\} 1 # \\{trace_id="${TRACE_ID}"\\}`,
      ),
    );
  });
});
