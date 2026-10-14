import { createServer, type IncomingMessage } from 'node:http';
import type { AddressInfo } from 'node:net';
import { beforeAll, describe, expect, it } from 'vitest';
import { createPool } from '../../src/db.ts';
import { startServer } from '../../src/server.ts';
import { resetDatabase, silentLogger, testConfig } from './helpers.ts';

const TRACE_ID = '0af7651916cd43dd8448eb211c80319c';
const PARENT_ID = 'b7ad6b7169203331';

interface OtlpSpan {
  traceId: string;
  spanId: string;
  parentSpanId?: string;
  name: string;
  kind: number;
}
interface OtlpExport {
  resourceSpans: { scopeSpans: { spans: OtlpSpan[] }[] }[];
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk: string) => {
      body += chunk;
    });
    req.once('end', () => {
      resolve(body);
    });
    req.once('error', reject);
  });
}

beforeAll(async () => {
  const pool = createPool(testConfig().db, silentLogger);
  await resetDatabase(pool);
  await pool.end();
});

describe('tracing', () => {
  it('exports the spans of a request and of its queries over OTLP/HTTP, at the latest on shutdown', async () => {
    // A stand-in for the OpenTelemetry Collector: records every OTLP/HTTP JSON export.
    const exports: OtlpExport[] = [];
    const collector = createServer((req, res) => {
      void readBody(req).then((body) => {
        if (req.method === 'POST' && req.url === '/v1/traces') {
          exports.push(JSON.parse(body) as OtlpExport);
        }
        res.writeHead(200, { 'Content-Type': 'application/json' }).end('{}');
      });
    });
    await new Promise<void>((resolve) => collector.listen(0, '127.0.0.1', resolve));
    const { port } = collector.address() as AddressInfo;

    const config = testConfig({ OTEL_EXPORTER_OTLP_ENDPOINT: `http://127.0.0.1:${port}/` });
    const running = await startServer({ ...config, port: 0, metricsPort: 0 }, silentLogger);
    const response = await fetch(`http://127.0.0.1:${running.port}/api/messages`, {
      headers: { traceparent: `00-${TRACE_ID}-${PARENT_ID}-01` },
    });
    expect(response.status).toBe(200);
    await running.shutdown('test');
    await new Promise<void>((resolve) => collector.close(() => resolve()));

    const spans = exports.flatMap((e) => e.resourceSpans.flatMap((r) => r.scopeSpans.flatMap((s) => s.spans)));
    const server = spans.find((s) => s.name === 'GET /api/messages');
    const query = spans.find((s) => s.name === `SELECT ${config.db.database}`);
    expect(server?.traceId).toBe(TRACE_ID);
    expect(server?.parentSpanId).toBe(PARENT_ID);
    expect(query?.traceId).toBe(TRACE_ID);
    expect(query?.parentSpanId).toBe(server?.spanId);
    // /healthz and /readyz never produce spans.
    expect(spans.every((s) => !s.name.includes('healthz') && !s.name.includes('readyz'))).toBe(true);
  });
});
