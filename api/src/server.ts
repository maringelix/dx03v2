// API entrypoint (`node dist/server.js`). startServer() is exported for the integration tests.
// Graceful shutdown on SIGTERM/SIGINT: readiness turns 503, server.close() waits for in-flight
// requests, then the pool is closed; the process is forced out after SHUTDOWN_TIMEOUT_MS.
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import type { Logger } from 'pino';
import { createApp } from './app.ts';
import { ConfigError, loadConfig, type Config } from './config.ts';
import { createPool, type DbPool } from './db.ts';
import { isMain, readVersion } from './entrypoint.ts';
import { createLogger } from './logger.ts';
import { createMetrics, createMetricsServer } from './metrics.ts';
import type { AppState } from './routes/health.ts';

export interface RunningServer {
  port: number;
  metricsPort: number;
  pool: DbPool;
  state: AppState;
  logger: Logger;
  /** Idempotent: every call returns the same promise. */
  shutdown: (reason: string) => Promise<void>;
}

function listen(server: Server, port: number): Promise<number> {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, () => {
      server.off('error', reject);
      resolve((server.address() as AddressInfo).port);
    });
  });
}

function close(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((err) => {
      if (err) {
        reject(err);
      } else {
        resolve();
      }
    });
  });
}

export async function startServer(config: Config, logger?: Logger): Promise<RunningServer> {
  const version = readVersion();
  const log = logger ?? createLogger({ level: config.logLevel, appEnv: config.appEnv, version, gitSha: config.gitSha });
  const pool = createPool(config.db, log);
  const metrics = createMetrics();
  const state: AppState = { shuttingDown: false };
  const server = createServer(createApp({ config, pool, logger: log, metrics, state, version }));
  // Keep-alive connections from the proxies must outlive their idle timeouts (nginx 60 s; the
  // Application Gateway for Containers timeouts are discussed in docs/ARQUITETURA.md).
  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 66_000;
  const metricsServer = createMetricsServer(metrics);
  const port = await listen(server, config.port);
  const metricsPort = await listen(metricsServer, config.metricsPort);
  log.info({ port, metricsPort, appEnv: config.appEnv, trustProxyHops: config.trustProxyHops }, 'api listening');

  let stopping: Promise<void> | undefined;
  const shutdown = (reason: string): Promise<void> => {
    stopping ??= (async () => {
      state.shuttingDown = true;
      log.info({ reason }, 'shutting down: readiness is now 503, waiting for in-flight requests');
      await Promise.all([close(server), close(metricsServer)]);
      await pool.end();
      log.info('shutdown complete');
    })();
    return stopping;
  };

  return { port, metricsPort, pool, state, logger: log, shutdown };
}

export async function main(env: NodeJS.ProcessEnv = process.env): Promise<void> {
  let config: Config;
  try {
    config = loadConfig(env);
  } catch (err) {
    if (err instanceof ConfigError) {
      process.stderr.write(`dx03v2-api: ${err.message}\n`);
      process.exitCode = 1;
      return;
    }
    throw err;
  }
  const running = await startServer(config);
  const onSignal = (signal: NodeJS.Signals) => {
    setTimeout(() => {
      running.logger.error({ timeoutMs: config.shutdownTimeoutMs }, 'graceful shutdown timed out, forcing exit');
      process.exit(1);
    }, config.shutdownTimeoutMs).unref();
    running.shutdown(signal).then(
      () => {
        process.exitCode = 0;
      },
      (err: unknown) => {
        running.logger.error({ err }, 'shutdown failed');
        process.exitCode = 1;
      },
    );
  };
  process.once('SIGTERM', onSignal);
  process.once('SIGINT', onSignal);
}

if (isMain(import.meta.url)) {
  await main();
}
