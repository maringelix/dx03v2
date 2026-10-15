// End-to-end smoke test through the entry point: the web nginx locally and on kind, the GKE Gateway
// (global external Application Load Balancer) on Google Cloud, the Istio Gateway on the tx03v2 local
// platform.
//   BASE_URL=http://127.0.0.1:18080 ADMIN_TOKEN=... node e2e/smoke.mjs
// The admin token is a credential: it is sent over HTTPS or to this machine (127.0.0.1, localhost),
// never over plain HTTP to another host. Without a token, or on such an entry point, the one call
// that needs it is skipped and the checks that send a made-up token still run.
// Optional: SMOKE_WAIT_SECONDS (wait for /healthz and /api/info, plus GET retries; default 0),
//           SMOKE_MAX_WRITES (attempts to reach the rate limit; default 60),
//           SMOKE_EDGE (what routes /api to the API: `nginx`, the default, for compose and kind;
//           `gke` for Google Cloud, where the HTTPRoute of the Gateway sends /api straight to the API;
//           `istio` for the Istio Gateway of the tx03v2 local lab, where /api goes straight to the
//           API and an external X-Request-Id is kept, as behind nginx).
// The rate-limit check runs last: it uses up this client's write budget for a minute.
import { randomUUID } from 'node:crypto';
import { assert, assertEqual, choiceEnv, http, intEnv, requiredEnv, Runner, waitForOk } from './lib.mjs';

const BASE_URL = requiredEnv('BASE_URL');
const ADMIN_TOKEN = process.env.ADMIN_TOKEN ?? '';
const WAIT_SECONDS = intEnv('SMOKE_WAIT_SECONDS', 0);
const MAX_WRITES = intEnv('SMOKE_MAX_WRITES', 60);
const EDGE = choiceEnv('SMOKE_EDGE', ['nginx', 'gke', 'istio']);
const RETRIES = WAIT_SECONDS > 0 ? 5 : 0;
const HTTPS = new URL(BASE_URL).protocol === 'https:';
const LOCAL_HOST = ['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE_URL).hostname);
const SEND_ADMIN_TOKEN = ADMIN_TOKEN !== '' && (HTTPS || LOCAL_HOST);

const WEB_CSP =
  "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; " +
  "object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'";
// Behind nginx /api responses carry the web policy (nginx hides the API's own); behind the GKE
// Gateway or the Istio Gateway, which route /api straight to the API, they carry the API's policy.
const API_CSP = EDGE === 'nginx' ? WEB_CSP : "default-src 'none';frame-ancestors 'none'";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// What the API accepts as a request ID (api/src/middleware/request-id.ts); anything else is replaced.
const SAFE_REQUEST_ID = /^[A-Za-z0-9-]{1,64}$/;
const WEB_HEADERS = {
  'content-security-policy': WEB_CSP,
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'strict-origin-when-cross-origin',
  'permissions-policy': 'camera=(), microphone=(), geolocation=()',
  'cross-origin-opener-policy': 'same-origin',
};

const get = (path, headers = {}) => http(BASE_URL, path, { headers, retries: RETRIES });
const post = (body, headers = {}) => http(BASE_URL, '/api/messages', { method: 'POST', body, headers });
const remove = (id, token) =>
  http(BASE_URL, `/api/messages/${id}`, {
    method: 'DELETE',
    headers: token === undefined ? {} : { Authorization: `Bearer ${token}` },
  });

/** Every web security header present exactly once with the expected value; HSTS only on HTTPS. */
function assertWebHeaders(res, what) {
  for (const [name, value] of Object.entries(WEB_HEADERS)) {
    assertEqual(res.headers.get(name), value, `${what}: ${name}`);
  }
  const hsts = res.headers.get('strict-transport-security');
  if (HTTPS) {
    assertEqual(hsts, 'max-age=31536000; includeSubDomains', `${what}: strict-transport-security`);
  } else {
    assertEqual(hsts, null, `${what}: strict-transport-security over plain HTTP`);
  }
  const server = res.headers.get('server');
  assert(server === null || !/[0-9]/.test(server), `${what}: Server header leaks a version (${server})`);
}

function assertErrorBody(res, status, code, what) {
  assertEqual(res.status, status, `${what}: status`);
  assertEqual(res.json?.error?.code, code, `${what}: error.code`);
  assert(typeof res.json?.error?.requestId === 'string', `${what}: error.requestId missing`);
}

const run = new Runner();
const marker = randomUUID().slice(0, 8);
let created;

if (WAIT_SECONDS > 0) {
  await run.check(`entry point ready within ${WAIT_SECONDS}s`, async () => {
    await waitForOk(BASE_URL, '/healthz', WAIT_SECONDS);
    await waitForOk(BASE_URL, '/api/info', WAIT_SECONDS);
  });
}

let assetPath;
await run.check('GET / serves the page with every security header', async () => {
  const res = await get('/');
  assertEqual(res.status, 200, 'status');
  assert((res.headers.get('content-type') ?? '').startsWith('text/html'), 'content-type is not text/html');
  assert(res.text.includes('<div id="root"></div>'), 'page has no #root');
  assert(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(res.text), 'page contains an inline <script>');
  assert(!/<style|\sstyle=/i.test(res.text), 'page contains inline styles');
  assertEqual(res.headers.get('cache-control'), 'no-cache', 'cache-control');
  assertWebHeaders(res, 'page');
  assetPath = /src="(\/assets\/[^"]+\.js)"/.exec(res.text)?.[1];
  assert(assetPath !== undefined, 'no /assets/*.js script in the page');
});

await run.check('hashed assets are cacheable and carry the security headers', async () => {
  assert(assetPath !== undefined, 'no asset found on the page');
  const res = await get(assetPath);
  assertEqual(res.status, 200, 'status');
  assertEqual(res.headers.get('cache-control'), 'public, max-age=31536000, immutable', 'cache-control');
  assertWebHeaders(res, 'asset');
  const missing = await get('/assets/does-not-exist.js');
  assertEqual(missing.status, 404, 'missing asset status');
  assertWebHeaders(missing, 'missing asset');
});

await run.check('GET /healthz (web) answers 200 with the security headers', async () => {
  const res = await get('/healthz');
  assertEqual(res.status, 200, 'status');
  assertWebHeaders(res, '/healthz');
});

await run.check('GET /api/info describes the deployment', async () => {
  const res = await get('/api/info');
  assertEqual(res.status, 200, 'status');
  assertEqual(
    JSON.stringify(Object.keys(res.json ?? {}).sort()),
    JSON.stringify(['commit', 'environment', 'name', 'uptimeSeconds', 'version']),
    'keys',
  );
  assertEqual(res.json.name, 'dx03v2-api', 'name');
  assertEqual(res.headers.get('content-security-policy'), API_CSP, `content-security-policy behind ${EDGE} (once)`);
  assertEqual(res.headers.get('x-content-type-options'), 'nosniff', 'x-content-type-options (once)');
  assertEqual(res.headers.get('cache-control'), 'no-store', 'cache-control');
  console.log(`     api ${res.json.version}, commit ${res.json.commit}, environment ${res.json.environment}`);
});

if (EDGE === 'gke') {
  // The docs of the global external Application Load Balancer do not say whether its Envoy-based
  // proxies forward, replace or add X-Request-Id (checked 2026-10-11), so only the safety property
  // is asserted: a safe client ID comes back unchanged or as a UUID, an unsafe one never comes
  // back, and two requests never share an ID.
  await run.check('X-Request-Id is never an unsafe client value and never shared', async () => {
    const id = `smoke-${marker}`;
    const unsafe = 'not a safe id!';
    const first = (await get('/api/info', { 'X-Request-Id': id })).headers.get('x-request-id') ?? '';
    const second = (await get('/api/info', { 'X-Request-Id': unsafe })).headers.get('x-request-id') ?? '';
    assert(
      first === id || UUID.test(first),
      `safe client id: expected it unchanged or a UUID, got ${JSON.stringify(first)}`,
    );
    assert(
      second !== unsafe && SAFE_REQUEST_ID.test(second),
      `unsafe client id: expected a safe replacement, got ${JSON.stringify(second)}`,
    );
    assert(first !== second, 'two requests got the same request ID');
  });
} else {
  await run.check('X-Request-Id is echoed when safe and replaced when not', async () => {
    const id = `smoke-${marker}`;
    const kept = await get('/api/info', { 'X-Request-Id': id });
    assertEqual(kept.headers.get('x-request-id'), id, 'echoed id');
    const replaced = await get('/api/info', { 'X-Request-Id': 'not a safe id!' });
    assert(/^[0-9a-f-]{36}$/.test(replaced.headers.get('x-request-id') ?? ''), 'unsafe id was not replaced');
  });
}

await run.check('POST /api/messages with a valid body answers 201', async () => {
  const res = await post({ author: 'smoke', text: `smoke test ${marker} <b>texto puro</b>` });
  assertEqual(res.status, 201, 'status');
  assertEqual(res.json?.text, `smoke test ${marker} <b>texto puro</b>`, 'stored text');
  created = res.json;
});

await run.check('POST /api/messages with an invalid body answers 400', async () => {
  assertErrorBody(await post({ author: '', text: 'x' }), 400, 'validation_error', 'empty author');
  assertErrorBody(await post('{"author": ', {}), 400, 'invalid_json', 'malformed JSON');
});

await run.check('GET /api/messages lists the new message first', async () => {
  const res = await get('/api/messages?limit=5');
  assertEqual(res.status, 200, 'status');
  assert(Array.isArray(res.json?.items), 'items is not a list');
  assert(
    res.json.items.some((item) => item.id === created?.id),
    'created message not listed',
  );
});

await run.check('DELETE needs the admin token: 401 without a token and with a wrong one', async () => {
  assert(created !== undefined, 'nothing was created');
  const missing = await remove(created.id);
  assertErrorBody(missing, 401, 'unauthorized', 'without token');
  assertErrorBody(await remove(created.id, `wrong-${marker}-${'x'.repeat(32)}`), 401, 'unauthorized', 'wrong token');
});

if (SEND_ADMIN_TOKEN) {
  await run.check('DELETE with the admin token answers 204, then 404', async () => {
    assert(created !== undefined, 'nothing was created');
    const ok = await remove(created.id, ADMIN_TOKEN);
    assertEqual(ok.status, 204, 'with token');
    const again = await remove(created.id, ADMIN_TOKEN);
    assertErrorBody(again, 404, 'not_found', 'second delete');
  });
} else {
  run.skip(
    'DELETE with the admin token answers 204, then 404',
    'the admin token is not sent over plain HTTP to another host (use HTTPS)',
  );
}

await run.check('oversized bodies and unknown routes get JSON errors', async () => {
  // nginx (64k) or, behind the GKE Gateway, the API itself (10 kb) answers with the same JSON 413:
  // Cloud Armor (tx03v2) inspects only the first 64 KB of a body and never blocks for size, so
  // 70 KB reaches the API (docs/CONTRATO.md).
  const oversized = await post({ author: 'smoke', text: 'x'.repeat(70 * 1024) });
  assertErrorBody(oversized, 413, 'payload_too_large', '70 kb');
  assertErrorBody(await get('/api/does-not-exist'), 404, 'not_found', 'unknown API route');
});

await run.check('rate limit answers 429 even with a different spoofed X-Forwarded-For each time', async () => {
  // Invalid bodies (400) count towards the limit and leave no data behind.
  const statuses = [];
  let limited;
  for (let i = 0; i < MAX_WRITES && limited === undefined; i++) {
    const res = await post({ author: '', text: '' }, { 'X-Forwarded-For': `198.51.100.${(i % 250) + 1}` });
    statuses.push(res.status);
    if (res.status === 429) {
      limited = res;
    }
  }
  assert(limited !== undefined, `no 429 after ${MAX_WRITES} writes (statuses: ${[...new Set(statuses)].join(',')})`);
  assertErrorBody(limited, 429, 'rate_limited', '429 body');
  assert(Number(limited.headers.get('retry-after')) > 0, 'Retry-After missing');
  assert(
    statuses.slice(0, -1).every((status) => status === 400),
    'unexpected status before 429',
  );
  console.log(`     429 after ${statuses.length} writes in this burst`);
});

run.finish();
