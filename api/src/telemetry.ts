// OpenTelemetry traces: W3C trace context in and out, spans exported over OTLP/HTTP to the Collector
// of the platform (OTEL_EXPORTER_OTLP_ENDPOINT; off when unset). The API creates its spans itself, with
// no module-patching loader (ESM): one SERVER span per HTTP request (tracingMiddleware) and one CLIENT
// span per PostgreSQL query made inside a request (instrumentPool). Logs and metrics carry the trace id
// of the active span (logger.ts, metrics.ts), so a log line or an exemplar leads to its trace.
import {
  context,
  isSpanContextValid,
  propagation,
  SpanKind,
  SpanStatusCode,
  trace,
  type Attributes,
  type SpanContext,
} from '@opentelemetry/api';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { BatchSpanProcessor, NodeTracerProvider, type SpanProcessor } from '@opentelemetry/sdk-trace-node';
import {
  ATTR_DB_NAMESPACE,
  ATTR_DB_OPERATION_NAME,
  ATTR_DB_QUERY_TEXT,
  ATTR_DB_SYSTEM_NAME,
  ATTR_ERROR_TYPE,
  ATTR_HTTP_REQUEST_METHOD,
  ATTR_HTTP_RESPONSE_STATUS_CODE,
  ATTR_HTTP_ROUTE,
  ATTR_SERVER_ADDRESS,
  ATTR_SERVER_PORT,
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
  ATTR_URL_PATH,
  DB_SYSTEM_NAME_VALUE_POSTGRESQL,
} from '@opentelemetry/semantic-conventions';
import type { RequestHandler } from 'express';
import type { QueryResult, QueryResultRow } from 'pg';
import type { DbConfig } from './config.ts';
import type { DbPool } from './db.ts';
import { routeLabel, setExemplarTraceId } from './metrics.ts';

export const SERVICE_NAME = 'dx03v2-api';
const TRACER = SERVICE_NAME;
/** Kubernetes probes: never traced (one span every few seconds per pod would drown the real traffic). */
const UNTRACED_PATHS = new Set(['/healthz', '/readyz']);

/** A Collector that does not answer delays an export (and the shutdown flush) by at most this. */
const EXPORT_TIMEOUT_MS = 5000;

export interface Telemetry {
  enabled: boolean;
  /**
   * Flushes the pending spans and unregisters the global provider. Idempotent; never rejects: a
   * Collector that is down must not turn a clean shutdown into a failed one (onShutdownError).
   */
  shutdown: () => Promise<void>;
}

export interface TelemetryOptions {
  endpoint: string | undefined;
  version: string;
  appEnv: string;
  gitSha: string;
  /** Called when the last spans could not be flushed on shutdown. */
  onShutdownError?: (err: unknown) => void;
  /** Test seam: a processor (e.g. an in-memory exporter) instead of the OTLP exporter. */
  spanProcessor?: SpanProcessor;
}

export function startTelemetry(options: TelemetryOptions): Telemetry {
  const { endpoint, spanProcessor } = options;
  if (endpoint === undefined && spanProcessor === undefined) {
    return { enabled: false, shutdown: () => Promise.resolve() };
  }
  const processor =
    spanProcessor ??
    new BatchSpanProcessor(new OTLPTraceExporter({ url: `${endpoint}/v1/traces`, timeoutMillis: EXPORT_TIMEOUT_MS }), {
      exportTimeoutMillis: EXPORT_TIMEOUT_MS,
    });
  const provider = new NodeTracerProvider({
    resource: resourceFromAttributes({
      [ATTR_SERVICE_NAME]: SERVICE_NAME,
      [ATTR_SERVICE_VERSION]: options.version,
      'service.namespace': 'dx03v2',
      'deployment.environment.name': options.appEnv,
      'vcs.ref.head.revision': options.gitSha,
    }),
    spanProcessors: [processor],
  });
  // Global tracer provider, AsyncLocalStorage context manager and W3C trace context propagator.
  provider.register();
  let stopping: Promise<void> | undefined;
  return {
    enabled: true,
    shutdown: () => {
      stopping ??= provider
        .shutdown()
        .catch((err: unknown) => {
          options.onShutdownError?.(err);
        })
        .finally(() => {
          trace.disable();
          context.disable();
          propagation.disable();
        });
      return stopping;
    },
  };
}

/** The span context of the active span, when it is a real (valid) one. */
export function activeSpanContext(): SpanContext | undefined {
  const spanContext = trace.getActiveSpan()?.spanContext();
  return spanContext !== undefined && isSpanContextValid(spanContext) ? spanContext : undefined;
}

/**
 * First middleware: continues the trace of an incoming `traceparent` (the Gateway of the platform) or
 * starts one, and runs the rest of the request inside the SERVER span. The span is named after the
 * matched route pattern (trackRoute), never after the raw path.
 */
export function tracingMiddleware(): RequestHandler {
  return (req, res, next) => {
    if (UNTRACED_PATHS.has(req.path)) {
      next();
      return;
    }
    const parent = propagation.extract(context.active(), req.headers);
    const span = trace
      .getTracer(TRACER)
      .startSpan(
        req.method,
        { kind: SpanKind.SERVER, attributes: { [ATTR_HTTP_REQUEST_METHOD]: req.method, [ATTR_URL_PATH]: req.path } },
        parent,
      );
    const spanContext = span.spanContext();
    if (isSpanContextValid(spanContext)) {
      setExemplarTraceId(res, spanContext.traceId);
    }
    res.once('finish', () => {
      const route = routeLabel(res);
      if (route !== 'unmatched') {
        span.updateName(`${req.method} ${route}`);
        span.setAttribute(ATTR_HTTP_ROUTE, route);
      }
      span.setAttribute(ATTR_HTTP_RESPONSE_STATUS_CODE, res.statusCode);
      if (res.statusCode >= 500) {
        span.setAttribute(ATTR_ERROR_TYPE, String(res.statusCode));
        span.setStatus({ code: SpanStatusCode.ERROR });
      }
      span.end();
    });
    context.with(trace.setSpan(parent, span), next);
  };
}

type Query = (text: string, values?: unknown[]) => Promise<QueryResult<QueryResultRow>>;

/**
 * Wraps `pool.query` (promise form, the only one the API uses) so that a query made inside a traced
 * request gets a CLIENT span with the statement (parameterized: values never reach the span). Queries
 * outside a request (readiness ping, migrations) stay untraced.
 */
export function instrumentPool(pool: DbPool, db: Pick<DbConfig, 'host' | 'port' | 'database'>): DbPool {
  const query = pool.query.bind(pool) as Query;
  const traced: Query = async (text, values) => {
    if (activeSpanContext() === undefined) {
      return query(text, values);
    }
    const operation = /^\s*([A-Za-z]+)/.exec(text)?.[1]?.toUpperCase() ?? 'QUERY';
    const attributes: Attributes = {
      [ATTR_DB_SYSTEM_NAME]: DB_SYSTEM_NAME_VALUE_POSTGRESQL,
      [ATTR_DB_NAMESPACE]: db.database,
      [ATTR_DB_OPERATION_NAME]: operation,
      [ATTR_DB_QUERY_TEXT]: text,
      [ATTR_SERVER_ADDRESS]: db.host,
      [ATTR_SERVER_PORT]: db.port,
    };
    return trace
      .getTracer(TRACER)
      .startActiveSpan(`${operation} ${db.database}`, { kind: SpanKind.CLIENT, attributes }, async (span) => {
        try {
          const result = await query(text, values);
          span.setAttribute('db.response.returned_rows', result.rowCount ?? 0);
          return result;
        } catch (err) {
          const code = (err as { code?: unknown }).code;
          span.setAttribute(ATTR_ERROR_TYPE, typeof code === 'string' ? code : 'Error');
          span.setStatus({ code: SpanStatusCode.ERROR, message: err instanceof Error ? err.message : String(err) });
          throw err;
        } finally {
          span.end();
        }
      });
  };
  (pool as unknown as { query: Query }).query = traced;
  return pool;
}
