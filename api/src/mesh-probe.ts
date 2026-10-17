// CI-only client for the full-profile service-mesh exercise. It runs under a dedicated Kubernetes
// ServiceAccount so the waypoint policy can distinguish an allowed caller from an intruder.
import { randomBytes } from 'node:crypto';
import { isMain } from './entrypoint.ts';

type ProbeRuntime = {
  fetchImpl: typeof fetch;
  wait: (milliseconds: number) => Promise<void>;
  randomId: (purpose: 'retry' | 'isolation') => string;
  stdout: (line: string) => void;
  stderr: (line: string) => void;
};

type ProbeOverrides = Partial<ProbeRuntime>;

function fail(message: string, runtime: ProbeRuntime): never {
  runtime.stderr(`mesh-probe: ${message}`);
  process.exitCode = 1;
  throw new Error(message);
}

async function get(path: string, target: string, runtime: ProbeRuntime, probeId?: string): Promise<Response> {
  return runtime.fetchImpl(new URL(path, target), {
    headers: probeId ? { 'x-lab-probe-id': probeId } : undefined,
    signal: AbortSignal.timeout(7_000),
  });
}

async function runAllowed(target: string, runtime: ProbeRuntime): Promise<void> {
  const total = 400;
  const counts = { stable: 0, canary: 0 };
  for (let i = 0; i < total; i += 1) {
    const response = await get('/variant', target, runtime);
    if (!response.ok) fail(`/variant returned HTTP ${response.status}`, runtime);
    const variant = response.headers.get('x-lab-variant');
    if (variant !== 'stable' && variant !== 'canary') fail(`unexpected backend identity ${String(variant)}`, runtime);
    counts[variant] += 1;
  }

  const canaryRatio = counts.canary / total;
  if (counts.stable === 0 || counts.canary === 0 || canaryRatio < 0.12 || canaryRatio > 0.28) {
    fail(`80/20 split was outside the 12–28% sampling band: ${JSON.stringify(counts)}`, runtime);
  }

  const retryId = runtime.randomId('retry');
  const retryResponse = await get('/fail', target, runtime, retryId);
  if (retryResponse.status !== 503) fail(`/fail returned HTTP ${retryResponse.status}, expected 503`, runtime);

  // The retry policy allows two retries after the original request. Three consecutive canary 5xx
  // responses should open the circuit; the next request must fail closed without reaching that pod.
  await runtime.wait(2_500);
  const isolationId = runtime.randomId('isolation');
  const isolationResponse = await get('/fail', target, runtime, isolationId);
  if (isolationResponse.status !== 503) {
    fail(`/fail after canary ejection returned HTTP ${isolationResponse.status}`, runtime);
  }

  runtime.stdout(
    `MESH_PROBE_RESULT total=${total} stable=${counts.stable} canary=${counts.canary} retry_request_id=${retryId} isolation_request_id=${isolationId} fail_status=${retryResponse.status}`,
  );
}

async function runIntruder(target: string, runtime: ProbeRuntime): Promise<void> {
  const response = await get('/variant', target, runtime);
  if (response.status !== 403) {
    fail(`unauthorized identity received HTTP ${response.status}, expected 403`, runtime);
  }
  runtime.stdout('MESH_PROBE_DENIED status=403');
}

export async function main(env: NodeJS.ProcessEnv = process.env, overrides: ProbeOverrides = {}): Promise<void> {
  const runtime: ProbeRuntime = {
    fetchImpl: overrides.fetchImpl ?? ((input, init) => fetch(input, init)),
    wait: overrides.wait ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))),
    randomId: overrides.randomId ?? ((purpose) => `mesh_${purpose}_${randomBytes(8).toString('hex')}`),
    stdout: overrides.stdout ?? ((line) => process.stdout.write(`${line}\n`)),
    stderr: overrides.stderr ?? ((line) => process.stderr.write(`${line}\n`)),
  };
  const mode = env.MESH_PROBE_MODE;
  if (mode !== 'allowed' && mode !== 'intruder') fail('MESH_PROBE_MODE must be allowed or intruder', runtime);
  const target = env.MESH_PROBE_TARGET ?? 'http://mesh-demo:3000';
  if (mode === 'allowed') await runAllowed(target, runtime);
  else await runIntruder(target, runtime);
}

if (isMain(import.meta.url)) {
  await main();
}
