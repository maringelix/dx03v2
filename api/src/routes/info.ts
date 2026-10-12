// GET /api/info: build and runtime identity for the UI footer. Never secrets or database details.
import express, { type Router } from 'express';
import type { Config } from '../config.ts';
import { trackRoute } from '../metrics.ts';

export function infoRouter(config: Config, version: string): Router {
  const router = express.Router();
  router.get('/info', trackRoute, (_req, res) => {
    res.json({
      name: 'dx03v2-api',
      version,
      commit: config.gitSha,
      environment: config.appEnv,
      uptimeSeconds: Math.floor(process.uptime()),
    });
  });
  return router;
}
