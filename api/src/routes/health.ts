// Probes. /healthz (liveness, startup) has no dependencies; /readyz (readiness) answers 200 only
// when the database replies to SELECT 1 within 1 s and the process is not shutting down.
import express, { type Router } from 'express';
import { ping, type DbPool } from '../db.ts';
import { trackRoute } from '../metrics.ts';

export const READY_TIMEOUT_MS = 1000;

export interface AppState {
  shuttingDown: boolean;
}

export function healthRouter(pool: DbPool, state: AppState): Router {
  const router = express.Router();

  router.get('/healthz', trackRoute, (_req, res) => {
    res.json({ status: 'ok' });
  });

  router.get('/readyz', trackRoute, async (_req, res) => {
    if (state.shuttingDown) {
      res.status(503).json({ status: 'shutting_down' });
      return;
    }
    const ready = await ping(pool, READY_TIMEOUT_MS);
    res.status(ready ? 200 : 503).json({ status: ready ? 'ready' : 'db_unavailable' });
  });

  return router;
}
