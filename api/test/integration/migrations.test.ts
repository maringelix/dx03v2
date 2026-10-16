import { copyFileSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { createPool, type DbPool } from '../../src/db.ts';
import { listMigrationFiles, main, MIGRATIONS_DIR, runMigrations, waitForDatabase } from '../../src/migrate.ts';
import { silentLogger, testConfig } from './helpers.ts';

const FIRST = '0001_create_messages.sql';
const EXPANSION = '0002_expand_message_display_name.sql';
let pool: DbPool;
const scratch: string[] = [];

/** Marks a file that is copied unchanged from api/migrations. */
const COPY = Symbol('copy');

function migrationsDir(files: Record<string, string | typeof COPY>): URL {
  const dir = mkdtempSync(join(tmpdir(), 'dx03v2-migrations-'));
  scratch.push(dir);
  for (const [name, content] of Object.entries(files)) {
    if (content === COPY) {
      copyFileSync(fileURLToPath(new URL(name, MIGRATIONS_DIR)), join(dir, name));
    } else {
      writeFileSync(join(dir, name), content);
    }
  }
  return pathToFileURL(`${dir}/`);
}

async function tableExists(name: string): Promise<boolean> {
  const result = await pool.query<{ exists: boolean }>('SELECT to_regclass($1) IS NOT NULL AS exists', [name]);
  return result.rows[0]?.exists === true;
}

beforeAll(() => {
  pool = createPool(testConfig().db, silentLogger);
});

afterAll(async () => {
  // Leave a clean schema for the other files (some cases here store fake checksums).
  await pool.query('DROP TABLE IF EXISTS messages, schema_migrations, broken_example');
  await pool.end();
  for (const dir of scratch) {
    rmSync(dir, { recursive: true, force: true });
  }
});

beforeEach(async () => {
  await pool.query('DROP TABLE IF EXISTS messages, schema_migrations, broken_example');
});

describe('runMigrations', () => {
  it('applies every file once and is idempotent', async () => {
    const files = await listMigrationFiles();
    expect(files[0]).toBe(FIRST);

    const first = await runMigrations(pool, silentLogger);
    expect(first).toEqual({ applied: files, skipped: [] });
    const second = await runMigrations(pool, silentLogger);
    expect(second).toEqual({ applied: [], skipped: files });

    const tracked = await pool.query<{ version: string }>('SELECT version FROM schema_migrations ORDER BY version');
    expect(tracked.rows.map((row) => row.version)).toEqual(files);
    const columns = await pool.query<{ column_name: string }>(
      "SELECT column_name FROM information_schema.columns WHERE table_name = 'messages' ORDER BY ordinal_position",
    );
    expect(columns.rows.map((row) => row.column_name)).toEqual(['id', 'author', 'body', 'created_at', 'display_name']);
  });

  it('keeps previous-release writes compatible with the additive expansion', async () => {
    await runMigrations(pool, silentLogger);
    // This is the SQL shape used by the previous release: it does not know about display_name.
    await pool.query('INSERT INTO messages (author, body) VALUES ($1, $2)', ['old-release', 'still works']);
    const oldProjection = await pool.query<{ author: string; body: string }>(
      'SELECT author, body FROM messages WHERE author = $1',
      ['old-release'],
    );
    expect(oldProjection.rows).toEqual([{ author: 'old-release', body: 'still works' }]);
    const expansion = await pool.query<{ display_name: string | null }>(
      'SELECT display_name FROM messages WHERE author = $1',
      ['old-release'],
    );
    expect(expansion.rows).toEqual([{ display_name: null }]);
  });

  it('contracts only after backfill and an old-release writer is retired', async () => {
    await runMigrations(pool, silentLogger);
    await pool.query('INSERT INTO messages (author, body) VALUES ($1, $2)', ['old-release', 'before backfill']);
    await pool.query('UPDATE messages SET display_name = author WHERE display_name IS NULL');
    const contract = migrationsDir({
      [FIRST]: COPY,
      [EXPANSION]: COPY,
      '0003_contract_display_name.sql': 'ALTER TABLE messages ALTER COLUMN display_name SET NOT NULL;',
    });
    await expect(runMigrations(pool, silentLogger, contract)).resolves.toEqual({
      applied: ['0003_contract_display_name.sql'],
      skipped: [FIRST, EXPANSION],
    });
    await expect(
      pool.query('INSERT INTO messages (author, body, display_name) VALUES ($1, $2, $3)', [
        'new-release',
        'after contract',
        'new-release',
      ]),
    ).resolves.toMatchObject({ rowCount: 1 });
    await expect(
      pool.query('INSERT INTO messages (author, body) VALUES ($1, $2)', ['old-release', 'too late']),
    ).rejects.toThrow();
  });

  it('serializes concurrent runners with the advisory lock', async () => {
    const other = createPool(testConfig().db, silentLogger);
    try {
      const results = await Promise.all([runMigrations(pool, silentLogger), runMigrations(other, silentLogger)]);
      const applied = results.flatMap((result) => result.applied);
      expect(applied).toEqual(await listMigrationFiles());
    } finally {
      await other.end();
    }
  });

  it('refuses an applied migration that was edited afterwards', async () => {
    await runMigrations(pool, silentLogger);
    const edited = migrationsDir({ [FIRST]: 'CREATE TABLE messages (id integer);' });
    await expect(runMigrations(pool, silentLogger, edited)).rejects.toThrow(/changed after it was applied/);
  });

  it('rolls back a failing migration completely', async () => {
    const dir = migrationsDir({
      [FIRST]: COPY,
      '0002_broken.sql': 'CREATE TABLE broken_example (id integer); SELECT * FROM table_that_does_not_exist;',
    });
    await expect(runMigrations(pool, silentLogger, dir)).rejects.toThrow(/table_that_does_not_exist/);
    expect(await tableExists('messages')).toBe(true);
    expect(await tableExists('broken_example')).toBe(false);
    const tracked = await pool.query('SELECT 1 FROM schema_migrations WHERE version = $1', ['0002_broken.sql']);
    expect(tracked.rowCount).toBe(0);
  });

  it('rejects badly named migration files', async () => {
    await expect(listMigrationFiles(migrationsDir({ 'create-things.sql': 'SELECT 1;' }))).rejects.toThrow(
      /must look like 0001_name.sql: create-things.sql/,
    );
  });
});

describe('waitForDatabase', () => {
  it('retries and then gives up', async () => {
    const unreachable = createPool({ ...testConfig().db, host: '127.0.0.1', port: 1 }, silentLogger);
    const warn = vi.spyOn(silentLogger, 'warn');
    try {
      await expect(waitForDatabase(unreachable, silentLogger, 3, 10)).rejects.toThrow();
      expect(warn).toHaveBeenCalledTimes(2);
    } finally {
      warn.mockRestore();
      await unreachable.end();
    }
  });

  it('returns as soon as the database answers', async () => {
    await expect(waitForDatabase(pool, silentLogger, 1, 10)).resolves.toBeUndefined();
  });
});

describe('main (dist/migrate.js)', () => {
  it('migrates using the environment', async () => {
    const env = { ...process.env, LOG_LEVEL: 'silent', ADMIN_TOKEN: '' };
    expect(await main(env)).toBe(0);
    expect(await tableExists('messages')).toBe(true);
    expect(await main(env)).toBe(0);
  });

  it('exits 1 with a readable message on invalid configuration', async () => {
    const stderr = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      expect(await main({})).toBe(1);
      expect(String(stderr.mock.calls[0]?.[0])).toContain('dx03v2-migrate: invalid configuration');
    } finally {
      stderr.mockRestore();
    }
  });

  it('exits 1 when the migration fails', async () => {
    await pool.query('CREATE TABLE schema_migrations (version text PRIMARY KEY, checksum text NOT NULL)');
    await pool.query("INSERT INTO schema_migrations VALUES ($1, 'not-the-real-checksum')", [FIRST]);
    expect(await main({ ...process.env, LOG_LEVEL: 'silent', ADMIN_TOKEN: '' })).toBe(1);
  });
});
