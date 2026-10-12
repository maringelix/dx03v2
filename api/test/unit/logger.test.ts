import { Writable } from 'node:stream';
import { describe, expect, it } from 'vitest';
import { createLogger } from '../../src/logger.ts';

function capture() {
  const lines: string[] = [];
  const stream = new Writable({
    write(chunk: Buffer, _encoding, callback) {
      lines.push(chunk.toString('utf8'));
      callback();
    },
  });
  const logger = createLogger({ level: 'info', appEnv: 'ci', version: '2.0.0', gitSha: 'abc1234' }, stream);
  const records = () => lines.map((line) => JSON.parse(line) as Record<string, unknown>);
  return { logger, records };
}

describe('createLogger', () => {
  it('writes JSON with service metadata and a level label', () => {
    const { logger, records } = capture();
    logger.info({ answer: 42 }, 'hello');
    expect(records()[0]).toMatchObject({
      level: 'info',
      msg: 'hello',
      answer: 42,
      service: 'dx03v2-api',
      env: 'ci',
      version: '2.0.0',
      commit: 'abc1234',
    });
  });

  it('redacts credentials in headers and password/token fields', () => {
    const { logger, records } = capture();
    logger.info(
      {
        req: { headers: { authorization: 'Bearer secret-token-value', cookie: 'sid=secret', host: 'web' } },
        password: 'p1',
        token: 't1',
        db: { password: 'p2', host: 'db' },
        admin: { token: 't2' },
      },
      'request',
    );
    const record = records()[0];
    const text = JSON.stringify(record);
    for (const secret of ['secret-token-value', 'sid=secret', 'p1', 'p2', 't1', 't2']) {
      expect(text).not.toContain(secret);
    }
    expect(record).toMatchObject({
      req: { headers: { authorization: '[Redacted]', cookie: '[Redacted]', host: 'web' } },
      password: '[Redacted]',
      token: '[Redacted]',
      db: { password: '[Redacted]', host: 'db' },
      admin: { token: '[Redacted]' },
    });
  });

  it('honours the level', () => {
    const { logger, records } = capture();
    logger.debug('hidden');
    expect(records()).toHaveLength(0);
  });
});
