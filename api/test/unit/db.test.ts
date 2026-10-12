import { describe, expect, it } from 'vitest';
import type { DbConfig } from '../../src/config.ts';
import { sslOptions } from '../../src/db.ts';

const db: DbConfig = {
  host: 'db.example.com',
  port: 5432,
  database: 'dx03v2',
  user: 'app',
  password: 'unit-test-password',
  sslMode: 'disable',
  sslCa: undefined,
  poolMax: 10,
};

describe('sslOptions', () => {
  it('disables TLS for local databases', () => {
    expect(sslOptions(db)).toBe(false);
  });

  it('encrypts without verification for require', () => {
    expect(sslOptions({ ...db, sslMode: 'require' })).toEqual({ rejectUnauthorized: false });
  });

  it('verifies the chain against the CA bundle for verify-full', () => {
    const ca = '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n';
    expect(sslOptions({ ...db, sslMode: 'verify-full', sslCa: ca })).toEqual({ ca, rejectUnauthorized: true });
  });
});
