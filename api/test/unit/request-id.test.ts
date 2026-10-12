import { describe, expect, it } from 'vitest';
import { requestIdOf, resolveRequestId } from '../../src/middleware/request-id.ts';

const fixed = () => 'generated-id';

describe('resolveRequestId', () => {
  it.each(['abc', 'A-1-b-2', 'x'.repeat(64), '0f8fad5b-d9cb-469f-a165-70867728950e'])('reuses %s', (id) => {
    expect(resolveRequestId(id, fixed)).toBe(id);
  });

  it.each(['x'.repeat(65), '', 'has space', 'semi;colon', 'line\nbreak', '<script>', 'ünïcode', 'a_b'])(
    'replaces %j',
    (id) => {
      expect(resolveRequestId(id, fixed)).toBe('generated-id');
    },
  );

  it('replaces missing or repeated headers', () => {
    expect(resolveRequestId(undefined, fixed)).toBe('generated-id');
    expect(resolveRequestId(['a', 'b'], fixed)).toBe('generated-id');
  });

  it('generates UUIDs by default', () => {
    expect(resolveRequestId(undefined)).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
  });
});

describe('requestIdOf', () => {
  it('returns string ids only', () => {
    expect(requestIdOf({ id: 'abc' })).toBe('abc');
    expect(requestIdOf({ id: 7 })).toBe('unknown');
    expect(requestIdOf({})).toBe('unknown');
  });
});
