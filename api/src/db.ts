// PostgreSQL access. The pool is lazy: it opens connections on demand and drops broken ones,
// so the API recovers by itself when the database comes back (no "connect once at boot").
import { Pool, type PoolConfig } from 'pg';
import type { Logger } from 'pino';
import type { DbConfig } from './config.ts';

export type DbPool = Pool;

/** TLS options per DB_SSL_MODE: verify-full checks the chain against DB_SSL_CA_FILE and the hostname. */
export function sslOptions(db: DbConfig): PoolConfig['ssl'] {
  switch (db.sslMode) {
    case 'disable':
      return false;
    case 'require':
      return { rejectUnauthorized: false };
    case 'verify-full':
      return { ca: db.sslCa, rejectUnauthorized: true };
  }
}

export interface PoolOptions {
  /** Pool size override (the migration entrypoint needs a single connection). */
  max?: number;
}

export function createPool(db: DbConfig, logger: Logger, options: PoolOptions = {}): DbPool {
  const pool = new Pool({
    host: db.host,
    port: db.port,
    database: db.database,
    user: db.user,
    password: db.password,
    ssl: sslOptions(db),
    max: options.max ?? db.poolMax,
    connectionTimeoutMillis: 3000,
    idleTimeoutMillis: 30_000,
    statement_timeout: 5000,
    query_timeout: 6000,
    application_name: 'dx03v2-api',
    keepAlive: true,
  });
  // An idle client that loses its connection emits on the pool; without a listener the process dies.
  pool.on('error', (err: Error & { code?: string }) => {
    logger.warn({ err: { message: err.message, code: err.code } }, 'idle database connection failed and was discarded');
  });
  return pool;
}

/** true when `SELECT 1` succeeds within timeoutMs. Never rejects. */
export async function ping(pool: DbPool, timeoutMs: number): Promise<boolean> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<boolean>((resolve) => {
    timer = setTimeout(() => {
      resolve(false);
    }, timeoutMs);
  });
  const query = pool.query('SELECT 1').then(
    () => true,
    () => false,
  );
  try {
    return await Promise.race([query, timeout]);
  } finally {
    clearTimeout(timer);
  }
}
