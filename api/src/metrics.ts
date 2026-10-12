// Prometheus metrics on a separate port (METRICS_PORT), never exposed by the web or the ingress.
// The HTTP histogram is labelled with the matched route pattern (`/api/messages/:id`), or
// `unmatched` for 404s, so raw paths never create unbounded label values.
import { createServer, type Server } from 'node:http';
import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { collectDefaultMetrics, Histogram, Registry } from 'prom-client';

export interface Metrics {
  registry: Registry;
  httpDuration: Histogram<'method' | 'route' | 'status_code'>;
}

export function createMetrics(): Metrics {
  const registry = new Registry();
  collectDefaultMetrics({ register: registry });
  const httpDuration = new Histogram({
    name: 'http_request_duration_seconds',
    help: 'Duration of HTTP requests handled by the API, by method, matched route and status code',
    labelNames: ['method', 'route', 'status_code'] as const,
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    registers: [registry],
  });
  return { registry, httpDuration };
}

const routeOf = new WeakMap<Response, string>();

/**
 * First handler of every route: records the route pattern while `req.baseUrl` and `req.route`
 * still describe the match (Express restores `req.baseUrl` when a router exits with an error).
 */
export const trackRoute: RequestHandler = (req, res, next) => {
  const route: unknown = req.route;
  const path =
    typeof route === 'object' && route !== null && 'path' in route && typeof route.path === 'string' ? route.path : '';
  routeOf.set(res, path === '/' && req.baseUrl !== '' ? req.baseUrl : `${req.baseUrl}${path}`);
  next();
};

export function routeLabel(res: Response): string {
  return routeOf.get(res) ?? 'unmatched';
}

export function metricsMiddleware(metrics: Metrics): RequestHandler {
  return (req: Request, res: Response, next: NextFunction) => {
    const end = metrics.httpDuration.startTimer();
    res.once('finish', () => {
      end({ method: req.method, route: routeLabel(res), status_code: String(res.statusCode) });
    });
    next();
  };
}

/** Minimal HTTP server: GET /metrics only. */
export function createMetricsServer(metrics: Metrics): Server {
  return createServer((req, res) => {
    const path = (req.url ?? '').split('?')[0];
    if (req.method !== 'GET' || path !== '/metrics') {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('not found\n');
      return;
    }
    metrics.registry.metrics().then(
      (body) => {
        res.writeHead(200, { 'Content-Type': metrics.registry.contentType }).end(body);
      },
      () => {
        res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' }).end('metrics unavailable\n');
      },
    );
  });
}
