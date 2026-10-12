// Schema migrations: applies migrations/NNNN_name.sql in order, one transaction per file, under a
// PostgreSQL advisory lock (concurrent runners wait instead of racing), tracked in
// schema_migrations with a checksum. Re-running is a no-op; editing an applied file is an error.
// Entrypoint `node dist/migrate.js` (compose `migrate` service, Kubernetes initContainer).
import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { setTimeout as sleep } from 'node:timers/promises';
import type { Logger } from 'pino';
import { ConfigError, loadConfig } from './config.ts';
import { createPool, type DbPool } from './db.ts';
import { isMain, readVersion } from './entrypoint.ts';
import { createLogger } from './logger.ts';

export const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url);
const FILE_PATTERN = /^[0-9]{4}_[a-z0-9_]+\.sql$/;
const LOCK_SQL = "SELECT pg_advisory_lock(hashtextextended('dx03v2:schema_migrations', 0))";
const UNLOCK_SQL = "SELECT pg_advisory_unlock(hashtextextended('dx03v2:schema_migrations', 0))";

export interface MigrationResult {
  applied: string[];
  skipped: string[];
}

export async function listMigrationFiles(dir: URL = MIGRATIONS_DIR): Promise<string[]> {
  const names = await readdir(dir);
  const invalid = names.filter((name) => name.endsWith('.sql') && !FILE_PATTERN.test(name));
  if (invalid.length > 0) {
    throw new Error(`migration files must look like 0001_name.sql: ${invalid.join(', ')}`);
  }
  return names.filter((name) => FILE_PATTERN.test(name)).sort();
}

const sha256 = (text: string) => createHash('sha256').update(text, 'utf8').digest('hex');

export async function runMigrations(pool: DbPool, logger: Logger, dir: URL = MIGRATIONS_DIR): Promise<MigrationResult> {
  const files = await listMigrationFiles(dir);
  const client = await pool.connect();
  const result: MigrationResult = { applied: [], skipped: [] };
  try {
    await client.query(LOCK_SQL);
    try {
      await client.query(
        `CREATE TABLE IF NOT EXISTS schema_migrations (
           version text PRIMARY KEY,
           checksum text NOT NULL,
           applied_at timestamptz NOT NULL DEFAULT now()
         )`,
      );
      const done = await client.query<{ version: string; checksum: string }>(
        'SELECT version, checksum FROM schema_migrations',
      );
      const applied = new Map(done.rows.map((row) => [row.version, row.checksum]));
      for (const file of files) {
        const sql = await readFile(new URL(file, dir), 'utf8');
        const checksum = sha256(sql);
        const previous = applied.get(file);
        if (previous !== undefined) {
          if (previous !== checksum) {
            throw new Error(`migration ${file} changed after it was applied; add a new migration instead`);
          }
          result.skipped.push(file);
          continue;
        }
        await client.query('BEGIN');
        try {
          await client.query(sql);
          await client.query('INSERT INTO schema_migrations (version, checksum) VALUES ($1, $2)', [file, checksum]);
          await client.query('COMMIT');
        } catch (err) {
          await client.query('ROLLBACK');
          throw err;
        }
        logger.info({ migration: file }, 'migration applied');
        result.applied.push(file);
      }
    } finally {
      await client.query(UNLOCK_SQL);
    }
  } finally {
    client.release();
  }
  return result;
}

/** Waits until the database accepts connections (it may still be starting). */
export async function waitForDatabase(pool: DbPool, logger: Logger, attempts: number, delayMs: number): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    try {
      await pool.query('SELECT 1');
      return;
    } catch (err) {
      if (attempt >= attempts) {
        throw err;
      }
      const reason = err instanceof Error ? err.message : String(err);
      logger.warn({ attempt, attempts, reason }, 'database not reachable yet, retrying');
      await sleep(delayMs);
    }
  }
}

export async function main(env: NodeJS.ProcessEnv = process.env): Promise<number> {
  let config;
  try {
    config = loadConfig(env);
  } catch (err) {
    if (err instanceof ConfigError) {
      process.stderr.write(`dx03v2-migrate: ${err.message}\n`);
      return 1;
    }
    throw err;
  }
  const logger = createLogger({
    level: config.logLevel,
    appEnv: config.appEnv,
    version: readVersion(),
    gitSha: config.gitSha,
  }).child({ component: 'migrate' });
  const pool = createPool(config.db, logger, { max: 1 });
  try {
    await waitForDatabase(pool, logger, 30, 2000);
    const { applied, skipped } = await runMigrations(pool, logger);
    logger.info({ applied: applied.length, alreadyApplied: skipped.length }, 'migrations complete');
    return 0;
  } catch (err) {
    logger.error({ err }, 'migrations failed');
    return 1;
  } finally {
    await pool.end();
  }
}

if (isMain(import.meta.url)) {
  process.exitCode = await main();
}
