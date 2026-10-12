// Helpers for e2e/smoke.mjs (plain Node 24, no dependencies).

/** Reads a required environment variable or exits with an actionable message. */
export function requiredEnv(name) {
  const value = process.env[name];
  if (value === undefined || value === '') {
    console.error(`smoke: ${name} is required`);
    process.exit(2);
  }
  return value;
}

/** Reads an optional environment variable that must be one of `values` (the first is the default). */
export function choiceEnv(name, values) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') {
    return values[0];
  }
  if (!values.includes(raw)) {
    console.error(`smoke: ${name} must be one of ${values.join(', ')}`);
    process.exit(2);
  }
  return raw;
}

export function intEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') {
    return fallback;
  }
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0) {
    console.error(`smoke: ${name} must be a non-negative integer`);
    process.exit(2);
  }
  return value;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * HTTP request against BASE_URL. GETs are retried on network errors and 502/503/504 when
 * `retries` > 0 (a load balancer that is still probing its targets); writes are never retried.
 */
export async function http(baseUrl, path, { method = 'GET', headers = {}, body, retries = 0 } = {}) {
  const url = new URL(path, baseUrl);
  const init = { method, headers: { ...headers }, redirect: 'manual' };
  if (body !== undefined) {
    init.body = typeof body === 'string' ? body : JSON.stringify(body);
    init.headers['Content-Type'] ??= 'application/json';
  }
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await fetch(url, { ...init, signal: AbortSignal.timeout(15_000) });
      if (method === 'GET' && attempt < retries && [502, 503, 504].includes(response.status)) {
        await sleep(2000);
        continue;
      }
      const text = await response.text();
      let json;
      try {
        json = text === '' ? undefined : JSON.parse(text);
      } catch {
        json = undefined;
      }
      return { status: response.status, headers: response.headers, text, json };
    } catch (err) {
      if (method === 'GET' && attempt < retries) {
        await sleep(2000);
        continue;
      }
      throw new Error(`${method} ${url.pathname} failed: ${err instanceof Error ? err.message : String(err)}`, {
        cause: err,
      });
    }
  }
}

/** Polls GET path until it answers 200 or the deadline passes. */
export async function waitForOk(baseUrl, path, seconds) {
  const deadline = Date.now() + seconds * 1000;
  let last = 'no response';
  while (Date.now() < deadline) {
    try {
      const res = await http(baseUrl, path);
      if (res.status === 200) {
        return;
      }
      last = `HTTP ${res.status}`;
    } catch (err) {
      last = err instanceof Error ? err.message : String(err);
    }
    await sleep(3000);
  }
  throw new Error(`${path} did not answer 200 within ${seconds}s (last: ${last})`);
}

export class AssertionError extends Error {}

export function assert(condition, message) {
  if (!condition) {
    throw new AssertionError(message);
  }
}

export function assertEqual(actual, expected, what) {
  assert(actual === expected, `${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

/** Runs named checks in order and prints PASS/FAIL lines; never prints secrets. */
export class Runner {
  passed = 0;
  failed = 0;

  async check(name, fn) {
    const start = Date.now();
    try {
      await fn();
      this.passed++;
      console.log(`PASS ${name} (${Date.now() - start}ms)`);
    } catch (err) {
      this.failed++;
      console.log(`FAIL ${name} (${Date.now() - start}ms): ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  finish() {
    console.log(`smoke: ${this.passed} passed, ${this.failed} failed`);
    process.exitCode = this.failed === 0 ? 0 : 1;
  }
}
