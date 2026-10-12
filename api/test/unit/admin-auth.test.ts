import express from 'express';
import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { bearerToken, requireAdmin, tokensMatch } from '../../src/middleware/admin-auth.ts';
import { errorHandler } from '../../src/middleware/errors.ts';

const TOKEN = 'a'.repeat(24) + 'B'.repeat(24);

function appWith(adminToken: string | undefined) {
  const app = express();
  app.delete('/thing', requireAdmin(adminToken), (_req, res) => {
    res.status(204).end();
  });
  app.use(errorHandler);
  return app;
}

describe('tokensMatch', () => {
  it('compares tokens of any length without throwing', () => {
    expect(tokensMatch(TOKEN, TOKEN)).toBe(true);
    expect(tokensMatch(`${TOKEN}x`, TOKEN)).toBe(false);
    expect(tokensMatch('', TOKEN)).toBe(false);
    expect(tokensMatch('b'.repeat(48), TOKEN)).toBe(false);
  });
});

describe('bearerToken', () => {
  it.each([
    ['Bearer abc.DEF-123_~+/=', 'abc.DEF-123_~+/='],
    ['bearer abc', undefined],
    ['Basic abc', undefined],
    ['Bearer', undefined],
    ['Bearer two words', undefined],
    [undefined, undefined],
  ])('parses %j', (header, expected) => {
    expect(bearerToken(header)).toBe(expected);
  });
});

describe('requireAdmin', () => {
  it('answers 503 admin_disabled when no token is configured', async () => {
    const res = await request(appWith(undefined)).delete('/thing').set('Authorization', `Bearer ${TOKEN}`);
    expect(res.status).toBe(503);
    expect(res.body.error.code).toBe('admin_disabled');
  });

  it('answers 401 with WWW-Authenticate without or with a wrong token', async () => {
    const app = appWith(TOKEN);
    for (const header of [undefined, `Bearer ${'x'.repeat(48)}`, `Basic ${TOKEN}`]) {
      const req = request(app).delete('/thing');
      const res = header === undefined ? await req : await req.set('Authorization', header);
      expect(res.status).toBe(401);
      expect(res.headers['www-authenticate']).toBe('Bearer realm="dx03v2"');
      expect(res.body.error.code).toBe('unauthorized');
    }
  });

  it('lets the right token through', async () => {
    const res = await request(appWith(TOKEN)).delete('/thing').set('Authorization', `Bearer ${TOKEN}`);
    expect(res.status).toBe(204);
  });
});
