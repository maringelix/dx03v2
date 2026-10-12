// Shared setup for the integration tests: a real PostgreSQL reached through the DB_* variables
// (scripts/harness.sh starts a throwaway postgres:17-alpine container when none is given).
import { createConnection, createServer, type Server, type Socket } from 'node:net';
import type { Express } from 'express';
import { pino, type Logger } from 'pino';
import { createApp } from '../../src/app.ts';
import { loadConfig, type Config } from '../../src/config.ts';
import { createPool, type DbPool } from '../../src/db.ts';
import { createMetrics, type Metrics } from '../../src/metrics.ts';
import { runMigrations } from '../../src/migrate.ts';
import type { AppState } from '../../src/routes/health.ts';

export const ADMIN_TOKEN = 'integration-admin-token-0123456789abcdef';

export const silentLogger: Logger = pino({ level: 'silent' });

export function testConfig(overrides: NodeJS.ProcessEnv = {}): Config {
  for (const key of ['DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASSWORD']) {
    if (!process.env[key]) {
      throw new Error(
        `integration tests need DB_HOST, DB_PORT, DB_NAME, DB_USER and DB_PASSWORD (${key} is missing); ` +
          'run `scripts/harness.sh test`, which starts a throwaway PostgreSQL',
      );
    }
  }
  return loadConfig({
    APP_ENV: 'ci',
    LOG_LEVEL: 'silent',
    DB_HOST: process.env.DB_HOST,
    DB_PORT: process.env.DB_PORT,
    DB_NAME: process.env.DB_NAME,
    DB_USER: process.env.DB_USER,
    DB_PASSWORD: process.env.DB_PASSWORD,
    DB_SSL_MODE: 'disable',
    ADMIN_TOKEN,
    GIT_SHA: '0123456789abcdef0123456789abcdef01234567',
    ...overrides,
  });
}

export interface TestApp {
  app: Express;
  pool: DbPool;
  state: AppState;
  metrics: Metrics;
  config: Config;
  close: () => Promise<void>;
}

export function createTestApp(overrides: NodeJS.ProcessEnv = {}, configure?: (config: Config) => Config): TestApp {
  const base = testConfig(overrides);
  const config = configure ? configure(base) : base;
  const pool = createPool(config.db, silentLogger);
  const metrics = createMetrics();
  const state: AppState = { shuttingDown: false };
  const app = createApp({ config, pool, logger: silentLogger, metrics, state, version: '2.0.0-test' });
  return { app, pool, state, metrics, config, close: () => pool.end() };
}

/** Recreates the schema from the migrations, independent of what earlier runs left behind. */
export async function resetDatabase(pool: DbPool): Promise<void> {
  await pool.query('DROP TABLE IF EXISTS messages, schema_migrations, broken_example');
  await runMigrations(pool, silentLogger);
}

/** TCP proxy in front of PostgreSQL to simulate an outage and a recovery without restarting it. */
export class TcpProxy {
  private server: Server | undefined;
  private readonly sockets = new Set<Socket>();
  private readonly targetHost: string;
  private readonly targetPort: number;

  constructor(targetHost: string, targetPort: number) {
    this.targetHost = targetHost;
    this.targetPort = targetPort;
  }

  start(port = 0): Promise<number> {
    const server = createServer((client) => {
      const upstream = createConnection(this.targetPort, this.targetHost);
      for (const socket of [client, upstream]) {
        this.sockets.add(socket);
        socket.on('close', () => this.sockets.delete(socket));
        socket.on('error', () => {
          client.destroy();
          upstream.destroy();
        });
      }
      client.pipe(upstream).pipe(client);
    });
    this.server = server;
    return new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, '127.0.0.1', () => {
        const address = server.address();
        resolve(typeof address === 'object' && address !== null ? address.port : port);
      });
    });
  }

  /** Stops accepting and cuts every open connection (like a database crash). */
  stop(): Promise<void> {
    for (const socket of this.sockets) {
      socket.destroy();
    }
    this.sockets.clear();
    const server = this.server;
    this.server = undefined;
    return new Promise((resolve) => {
      if (server === undefined) {
        resolve();
        return;
      }
      server.close(() => {
        resolve();
      });
    });
  }
}
