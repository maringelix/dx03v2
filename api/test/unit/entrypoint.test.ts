import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { afterAll, describe, expect, it } from 'vitest';
import { isMain, readVersion } from '../../src/entrypoint.ts';

const dir = mkdtempSync(join(tmpdir(), 'dx03v2-entrypoint-'));

afterAll(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe('isMain', () => {
  it('compares the module URL with the started script', () => {
    const script = join(dir, 'server.js');
    writeFileSync(script, '');
    expect(isMain(pathToFileURL(script).href, script)).toBe(true);
    expect(isMain(pathToFileURL(script).href, join(dir, 'other.js'))).toBe(false);
    expect(isMain(pathToFileURL(script).href, undefined)).toBe(false);
  });
});

describe('readVersion', () => {
  it('reads api/package.json', () => {
    expect(readVersion()).toMatch(/^[0-9]+\.[0-9]+\.[0-9]+/);
  });

  it('falls back when the version is missing', () => {
    const file = join(dir, 'package.json');
    writeFileSync(file, '{"name":"x"}');
    expect(readVersion(pathToFileURL(file))).toBe('0.0.0');
  });
});
