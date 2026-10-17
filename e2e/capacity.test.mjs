import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { summarize, meetsSlo, workload } from './capacity.mjs';

test('SLO counts errors and uses nearest-rank p99', () => {
  const samples = Array.from({ length: 100 }, (_, i) => ({ status: i === 0 ? 503 : 200, ms: i + 1 }));
  assert.deepEqual(summarize(samples), { requests: 100, failed: 1, p99Ms: 99 });
  assert.equal(meetsSlo(summarize(samples)), true);
  assert.equal(meetsSlo({ requests: 100, failed: 2, p99Ms: 99 }), false);
  assert.equal(meetsSlo({ requests: 100, failed: 0, p99Ms: 1501 }), false);
  assert.throws(() => summarize([]), /no load samples/);
});

test('unsafe/unbounded load is refused before any socket', async () => {
  await assert.rejects(workload('http://example.com/api/messages', 1, 1), /HTTPS/);
  await assert.rejects(workload('https://example.com/api/admin', 1, 1), /message reads/);
  await assert.rejects(workload('https://example.com/api/messages', 181, 1), /duration/);
  await assert.rejects(workload('https://example.com/api/messages', 1, 33), /concurrency/);
});

test('ConfigMap-style symlink entry executes the CLI instead of silently exiting', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'lab-capacity-entry-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const data = join(root, 'data');
  mkdirSync(data);
  copyFileSync(new URL('./capacity.mjs', import.meta.url), join(data, 'capacity.mjs'));
  const mount = join(root, 'mount');
  symlinkSync(data, mount, process.platform === 'win32' ? 'junction' : 'dir');
  const result = spawnSync(process.execPath, [join(mount, 'capacity.mjs')], {
    env: { ...process.env, CAPACITY_URL: 'http://example.com/api/messages' },
    encoding: 'utf8',
    timeout: 10000,
  });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /only HTTPS message reads are allowed/);
});
