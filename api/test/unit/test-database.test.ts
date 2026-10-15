import { describe, expect, it } from 'vitest';
import { requireTestDatabase } from '../integration/helpers.ts';

// The integration tests drop and recreate tables: DB_* exported for other work never reaches them.
const REFUSED = [undefined, '', 'dx03v2', 'postgres', 'test', '_test', 'dx03v2_test_backup', 'app-test'];

describe('requireTestDatabase', () => {
  it('accepts a database whose name ends in _test', () => {
    expect(requireTestDatabase('dx03v2_test')).toBe('dx03v2_test');
  });

  it.each(REFUSED)('refuses %j', (name) => {
    expect(() => requireTestDatabase(name)).toThrow(/DB_NAME must end in _test/);
  });
});
