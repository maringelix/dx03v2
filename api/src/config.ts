// Runtime configuration: one zod schema over the environment, validated once at startup.
// Anything invalid stops the process with a readable list of problems (values are never echoed).
import { readFileSync } from 'node:fs';
import { z } from 'zod';

const APP_ENVS = ['local', 'ci', 'kind', 'lab'] as const;
const LOG_LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent'] as const;
const DB_SSL_MODES = ['disable', 'require', 'verify-full'] as const;

/** Treats empty strings as "not set", so `FOO=` behaves like an absent variable. */
const optional = <T extends z.ZodType>(schema: T) =>
  z.preprocess((value) => (value === '' ? undefined : value), schema.optional());

const integer = (min: number, max: number, fallback: number) =>
  optional(
    z
      .string()
      .regex(/^[0-9]+$/, 'must be a whole number')
      .transform(Number)
      .pipe(z.number().int().min(min).max(max)),
  ).transform((value) => value ?? fallback);

const required = (what: string) =>
  z
    .string({ error: `${what} is required` })
    .trim()
    .min(1, `${what} is required`);

const envSchema = z
  .object({
    APP_ENV: optional(z.enum(APP_ENVS)).transform((value) => value ?? 'local'),
    PORT: integer(1, 65535, 3000),
    METRICS_PORT: integer(1, 65535, 9464),
    TRUST_PROXY_HOPS: integer(0, 10, 0),
    LOG_LEVEL: optional(z.enum(LOG_LEVELS)).transform((value) => value ?? 'info'),
    DB_HOST: required('DB_HOST'),
    DB_PORT: integer(1, 65535, 5432),
    DB_NAME: required('DB_NAME'),
    DB_USER: required('DB_USER'),
    DB_PASSWORD: z.string({ error: 'DB_PASSWORD is required' }).min(1, 'DB_PASSWORD is required'),
    DB_SSL_MODE: optional(z.enum(DB_SSL_MODES)).transform((value) => value ?? 'disable'),
    DB_SSL_CA_FILE: optional(z.string()),
    DB_POOL_MAX: integer(1, 100, 10),
    RATE_LIMIT_WRITE_PER_MINUTE: integer(1, 10000, 10),
    ADMIN_TOKEN: optional(z.string().min(32, 'ADMIN_TOKEN must have at least 32 characters')),
    GIT_SHA: optional(z.string().regex(/^[A-Za-z0-9._-]{1,64}$/, 'GIT_SHA has invalid characters')).transform(
      (value) => value ?? 'unknown',
    ),
    SHUTDOWN_TIMEOUT_MS: integer(100, 120000, 10000),
  })
  .superRefine((env, ctx) => {
    if (env.APP_ENV === 'lab' && env.DB_SSL_MODE !== 'verify-full') {
      ctx.addIssue({
        code: 'custom',
        path: ['DB_SSL_MODE'],
        message: 'DB_SSL_MODE must be verify-full when APP_ENV=lab',
      });
    }
    if (env.DB_SSL_MODE === 'verify-full' && env.DB_SSL_CA_FILE === undefined) {
      ctx.addIssue({
        code: 'custom',
        path: ['DB_SSL_CA_FILE'],
        message: 'DB_SSL_CA_FILE is required when DB_SSL_MODE=verify-full',
      });
    }
    if (env.PORT === env.METRICS_PORT) {
      ctx.addIssue({ code: 'custom', path: ['METRICS_PORT'], message: 'METRICS_PORT must differ from PORT' });
    }
  });

export type AppEnv = (typeof APP_ENVS)[number];
export type DbSslMode = (typeof DB_SSL_MODES)[number];

export interface DbConfig {
  host: string;
  port: number;
  database: string;
  user: string;
  password: string;
  sslMode: DbSslMode;
  /** PEM contents of DB_SSL_CA_FILE (verify-full only). */
  sslCa: string | undefined;
  poolMax: number;
}

export interface Config {
  appEnv: AppEnv;
  port: number;
  metricsPort: number;
  trustProxyHops: number;
  logLevel: (typeof LOG_LEVELS)[number];
  db: DbConfig;
  rateLimitWritePerMinute: number;
  adminToken: string | undefined;
  gitSha: string;
  shutdownTimeoutMs: number;
}

export class ConfigError extends Error {
  readonly problems: string[];

  constructor(problems: string[]) {
    super(`invalid configuration:\n${problems.map((p) => `  - ${p}`).join('\n')}`);
    this.name = 'ConfigError';
    this.problems = problems;
  }
}

export type ReadFile = (path: string) => string;

const readUtf8: ReadFile = (path) => readFileSync(path, 'utf8');

/**
 * Parses and validates the environment. Throws ConfigError listing every problem.
 * `readFile` is injectable so tests do not need real certificate files.
 */
export function loadConfig(env: NodeJS.ProcessEnv, readFile: ReadFile = readUtf8): Config {
  const parsed = envSchema.safeParse(env);
  if (!parsed.success) {
    throw new ConfigError(
      parsed.error.issues.map((issue) => {
        const key = issue.path.join('.');
        return issue.message.startsWith(key) ? issue.message : `${key}: ${issue.message}`;
      }),
    );
  }
  const e = parsed.data;
  let sslCa: string | undefined;
  if (e.DB_SSL_MODE === 'verify-full' && e.DB_SSL_CA_FILE !== undefined) {
    try {
      sslCa = readFile(e.DB_SSL_CA_FILE);
    } catch {
      throw new ConfigError([`DB_SSL_CA_FILE: cannot read ${e.DB_SSL_CA_FILE}`]);
    }
    if (!sslCa.includes('-----BEGIN CERTIFICATE-----')) {
      throw new ConfigError([`DB_SSL_CA_FILE: ${e.DB_SSL_CA_FILE} does not contain a PEM certificate`]);
    }
  }
  return {
    appEnv: e.APP_ENV,
    port: e.PORT,
    metricsPort: e.METRICS_PORT,
    trustProxyHops: e.TRUST_PROXY_HOPS,
    logLevel: e.LOG_LEVEL,
    db: {
      host: e.DB_HOST,
      port: e.DB_PORT,
      database: e.DB_NAME,
      user: e.DB_USER,
      password: e.DB_PASSWORD,
      sslMode: e.DB_SSL_MODE,
      sslCa,
      poolMax: e.DB_POOL_MAX,
    },
    rateLimitWritePerMinute: e.RATE_LIMIT_WRITE_PER_MINUTE,
    adminToken: e.ADMIN_TOKEN,
    gitSha: e.GIT_SHA,
    shutdownTimeoutMs: e.SHUTDOWN_TIMEOUT_MS,
  };
}
