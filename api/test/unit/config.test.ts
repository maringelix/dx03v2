import { describe, expect, it } from 'vitest';
import { ConfigError, loadConfig } from '../../src/config.ts';

const PEM = '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n';
const base = { DB_HOST: 'db', DB_NAME: 'dx03v2', DB_USER: 'app', DB_PASSWORD: 'unit-test-password' };

function problemsOf(env: NodeJS.ProcessEnv, readFile?: (path: string) => string): string[] {
  try {
    loadConfig(env, readFile);
  } catch (err) {
    if (err instanceof ConfigError) {
      return err.problems;
    }
    throw err;
  }
  throw new Error('expected a ConfigError');
}

describe('loadConfig', () => {
  it('applies the documented defaults', () => {
    const config = loadConfig(base);
    expect(config).toMatchObject({
      appEnv: 'local',
      port: 3000,
      metricsPort: 9464,
      trustProxyHops: 0,
      logLevel: 'info',
      rateLimitWritePerMinute: 10,
      adminToken: undefined,
      gitSha: 'unknown',
      shutdownTimeoutMs: 10000,
    });
    expect(config.db).toEqual({
      host: 'db',
      port: 5432,
      database: 'dx03v2',
      user: 'app',
      password: 'unit-test-password',
      sslMode: 'disable',
      sslCa: undefined,
      poolMax: 10,
    });
  });

  it('parses every variable', () => {
    const config = loadConfig({
      ...base,
      APP_ENV: 'kind',
      PORT: '8000',
      METRICS_PORT: '9000',
      TRUST_PROXY_HOPS: '1',
      LOG_LEVEL: 'debug',
      DB_PORT: '6432',
      DB_SSL_MODE: 'require',
      DB_POOL_MAX: '5',
      RATE_LIMIT_WRITE_PER_MINUTE: '30',
      ADMIN_TOKEN: 'x'.repeat(32),
      GIT_SHA: '0123456789abcdef0123456789abcdef01234567',
      SHUTDOWN_TIMEOUT_MS: '2500',
    });
    expect(config).toMatchObject({
      appEnv: 'kind',
      port: 8000,
      metricsPort: 9000,
      trustProxyHops: 1,
      logLevel: 'debug',
      rateLimitWritePerMinute: 30,
      adminToken: 'x'.repeat(32),
      gitSha: '0123456789abcdef0123456789abcdef01234567',
      shutdownTimeoutMs: 2500,
    });
    expect(config.db).toMatchObject({ port: 6432, sslMode: 'require', poolMax: 5 });
  });

  it('lists every missing required variable', () => {
    expect(problemsOf({})).toEqual([
      'DB_HOST is required',
      'DB_NAME is required',
      'DB_USER is required',
      'DB_PASSWORD is required',
    ]);
  });

  it('treats empty strings as unset', () => {
    const config = loadConfig({ ...base, ADMIN_TOKEN: '', PORT: '', APP_ENV: '' });
    expect(config.adminToken).toBeUndefined();
    expect(config.port).toBe(3000);
    expect(config.appEnv).toBe('local');
  });

  it.each([
    ['PORT', 'abc', 'PORT: must be a whole number'],
    ['PORT', '70000', 'PORT:'],
    ['TRUST_PROXY_HOPS', '-1', 'TRUST_PROXY_HOPS: must be a whole number'],
    ['DB_POOL_MAX', '0', 'DB_POOL_MAX:'],
    ['APP_ENV', 'production', 'APP_ENV:'],
    ['LOG_LEVEL', 'verbose', 'LOG_LEVEL:'],
    ['DB_SSL_MODE', 'prefer', 'DB_SSL_MODE:'],
    ['GIT_SHA', 'bad sha', 'GIT_SHA has invalid characters'],
  ])('rejects %s=%s', (key, value, expected) => {
    const problems = problemsOf({ ...base, [key]: value });
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain(expected);
  });

  it('rejects a short ADMIN_TOKEN without echoing it', () => {
    const problems = problemsOf({ ...base, ADMIN_TOKEN: 'short-secret-value' });
    expect(problems).toEqual(['ADMIN_TOKEN must have at least 32 characters']);
    expect(problems.join(' ')).not.toContain('short-secret-value');
  });

  it('never echoes the database password', () => {
    const problems = problemsOf({ ...base, PORT: 'x' });
    expect(problems.join(' ')).not.toContain('unit-test-password');
  });

  it('refuses PORT equal to METRICS_PORT', () => {
    expect(problemsOf({ ...base, PORT: '9000', METRICS_PORT: '9000' })).toEqual(['METRICS_PORT must differ from PORT']);
  });

  it.each(['disable', 'require'])('refuses DB_SSL_MODE=%s when APP_ENV=lab', (mode) => {
    expect(problemsOf({ ...base, APP_ENV: 'lab', DB_SSL_MODE: mode })).toContain(
      'DB_SSL_MODE must be verify-full when APP_ENV=lab',
    );
  });

  it('requires DB_SSL_CA_FILE for verify-full', () => {
    expect(problemsOf({ ...base, DB_SSL_MODE: 'verify-full' })).toEqual([
      'DB_SSL_CA_FILE is required when DB_SSL_MODE=verify-full',
    ]);
  });

  it('loads the CA bundle for verify-full', () => {
    const config = loadConfig(
      { ...base, APP_ENV: 'lab', DB_SSL_MODE: 'verify-full', DB_SSL_CA_FILE: '/etc/azure-pg-ca/ca.pem' },
      (path) => (path === '/etc/azure-pg-ca/ca.pem' ? PEM : ''),
    );
    expect(config.db.sslMode).toBe('verify-full');
    expect(config.db.sslCa).toBe(PEM);
  });

  it('fails when the CA file cannot be read', () => {
    const env = { ...base, DB_SSL_MODE: 'verify-full', DB_SSL_CA_FILE: '/missing.pem' };
    expect(
      problemsOf(env, () => {
        throw new Error('ENOENT');
      }),
    ).toEqual(['DB_SSL_CA_FILE: cannot read /missing.pem']);
  });

  it('fails when the CA file is not PEM', () => {
    const env = { ...base, DB_SSL_MODE: 'verify-full', DB_SSL_CA_FILE: '/ca.txt' };
    expect(problemsOf(env, () => 'not a certificate')).toEqual([
      'DB_SSL_CA_FILE: /ca.txt does not contain a PEM certificate',
    ]);
  });

  it('formats the error message as a readable list', () => {
    expect(() => loadConfig({})).toThrowError(/invalid configuration:\n {2}- DB_HOST is required/);
  });
});
