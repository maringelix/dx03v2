// Express application factory. Dependencies are injected so tests run the real app against a real
// PostgreSQL without starting a server (supertest), and server.ts wires the same app for production.
import express, { type Express } from 'express';
import helmet from 'helmet';
import type { Logger } from 'pino';
import { pinoHttp } from 'pino-http';
import type { Config } from './config.ts';
import type { DbPool } from './db.ts';
import { metricsMiddleware, type Metrics } from './metrics.ts';
import { errorHandler, notFound } from './middleware/errors.ts';
import { REQUEST_ID_HEADER, resolveRequestId } from './middleware/request-id.ts';
import { healthRouter, type AppState } from './routes/health.ts';
import { infoRouter } from './routes/info.ts';
import { messagesRouter } from './routes/messages.ts';
import { tracingMiddleware } from './telemetry.ts';

export interface AppDeps {
  config: Config;
  pool: DbPool;
  logger: Logger;
  metrics: Metrics;
  state: AppState;
  version: string;
}

const PROBE_PATHS = new Set(['/healthz', '/readyz']);

export function createApp({ config, pool, logger, metrics, state, version }: AppDeps): Express {
  const app = express();
  app.disable('x-powered-by');
  // Number of reverse proxies in front of the API (web nginx or Application Gateway for
  // Containers): req.ip is the address the outermost trusted proxy saw. Never `true`, which would
  // trust any X-Forwarded-For.
  app.set('trust proxy', config.trustProxyHops);

  // First: everything below (the request log included) runs inside the SERVER span of the request.
  // Without a tracer provider (OTEL_EXPORTER_OTLP_ENDPOINT unset) the span is a no-op.
  app.use(tracingMiddleware());
  app.use(
    pinoHttp({
      logger,
      quietReqLogger: true,
      genReqId: (req, res) => {
        const id = resolveRequestId(req.headers['x-request-id']);
        res.setHeader(REQUEST_ID_HEADER, id);
        return id;
      },
      customLogLevel: (_req, res, err) => {
        if (err !== undefined || res.statusCode >= 500) {
          return 'error';
        }
        return res.statusCode >= 400 ? 'warn' : 'info';
      },
      autoLogging: { ignore: (req) => PROBE_PATHS.has(req.url ?? '') },
    }),
  );
  app.use(metricsMiddleware(metrics));
  app.use(
    helmet({
      contentSecurityPolicy: {
        useDefaults: false,
        directives: { 'default-src': ["'none'"], 'frame-ancestors': ["'none'"] },
      },
      // HSTS is decided at the edge, and only for HTTPS requests (web/nginx/default.conf).
      strictTransportSecurity: false,
    }),
  );
  app.use((_req, res, next) => {
    res.setHeader('Cache-Control', 'no-store');
    next();
  });

  app.use(healthRouter(pool, state));
  app.use('/api', infoRouter(config, version));
  app.use('/api', messagesRouter(config, pool));
  app.use(notFound);
  app.use(errorHandler);
  return app;
}
