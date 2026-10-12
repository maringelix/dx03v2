import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { errorBody, HttpError, isDbUnavailable, mapError, summarizeIssues } from '../../src/errors.ts';

function bodyParserError(type: string, status: number): Error {
  return Object.assign(new Error('raw parser message with internals'), { type, status });
}

describe('mapError', () => {
  it('keeps HttpError status, code and message', () => {
    expect(mapError(new HttpError(404, 'not_found', 'Message not found'))).toEqual({
      status: 404,
      code: 'not_found',
      message: 'Message not found',
      internal: false,
    });
  });

  it('turns zod errors into a 400 with a summary', () => {
    const result = z.object({ a: z.string(), b: z.number() }).safeParse({ a: 1, b: 'x' });
    const mapped = mapError(result.error);
    expect(mapped.status).toBe(400);
    expect(mapped.code).toBe('validation_error');
    expect(mapped.message).toMatch(/^a: .+; b: .+$/);
  });

  it.each([
    ['entity.parse.failed', 400, 400, 'invalid_json'],
    ['entity.too.large', 413, 413, 'payload_too_large'],
    ['encoding.unsupported', 415, 415, 'unsupported_media_type'],
    ['charset.unsupported', 415, 415, 'unsupported_media_type'],
    ['request.aborted', 400, 400, 'bad_request'],
  ])('maps body-parser %s', (type, rawStatus, status, code) => {
    const mapped = mapError(bodyParserError(type, rawStatus));
    expect(mapped).toMatchObject({ status, code, internal: false });
    expect(mapped.message).not.toContain('internals');
  });

  it('maps database outages to 503', () => {
    const refused = Object.assign(new Error('connect ECONNREFUSED 10.0.0.5:5432'), { code: 'ECONNREFUSED' });
    expect(mapError(refused)).toMatchObject({ status: 503, code: 'db_unavailable', internal: true });
  });

  it('hides everything else behind a generic 500', () => {
    const mapped = mapError(new Error('duplicate key value violates unique constraint "secret_idx"'));
    expect(mapped).toEqual({ status: 500, code: 'internal_error', message: 'Internal server error', internal: true });
    expect(mapError('a string')).toMatchObject({ status: 500, internal: true });
    expect(mapError(null)).toMatchObject({ status: 500, internal: true });
  });
});

describe('isDbUnavailable', () => {
  it.each([
    [{ code: 'ECONNREFUSED' }, true],
    [{ code: 'ETIMEDOUT' }, true],
    [{ code: '08006' }, true],
    [{ code: '57P01' }, true],
    [{ code: '53300' }, true],
    [{ code: '23505' }, false],
    [{ code: '42P01' }, false],
  ])('classifies %j', (props, expected) => {
    expect(isDbUnavailable(Object.assign(new Error('x'), props))).toBe(expected);
  });

  it('recognizes driver messages without a code', () => {
    expect(isDbUnavailable(new Error('Connection terminated unexpectedly'))).toBe(true);
    expect(isDbUnavailable(new Error('timeout exceeded when trying to connect'))).toBe(true);
    expect(isDbUnavailable({ code: 'ECONNREFUSED' })).toBe(false);
  });
});

describe('summarizeIssues', () => {
  it('lists at most five issues', () => {
    const schema = z.object(Object.fromEntries(['a', 'b', 'c', 'd', 'e', 'f', 'g'].map((k) => [k, z.string()])));
    const result = schema.safeParse({});
    expect(summarizeIssues(result.error!)).toMatch(/^a: .*; e: [^;]+; and 2 more$/);
  });

  it('omits the path for top-level issues', () => {
    const result = z.string('body must be text').safeParse(1);
    expect(summarizeIssues(result.error!)).toBe('body must be text');
  });
});

describe('errorBody', () => {
  it('has the documented shape', () => {
    expect(errorBody('x', 'y', 'z')).toEqual({ error: { code: 'x', message: 'y', requestId: 'z' } });
  });
});
