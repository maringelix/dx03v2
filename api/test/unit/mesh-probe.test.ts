import { afterEach, describe, expect, it, vi } from 'vitest';
import { main } from '../../src/mesh-probe.ts';

type MockFetch = ReturnType<typeof installFetch>;

function response(status: number, variant?: string): Response {
  return new Response(null, {
    status,
    headers: variant === undefined ? {} : { 'x-lab-variant': variant },
  });
}

function requestPath(input: Parameters<typeof fetch>[0]): string {
  const address = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  return new URL(address).pathname;
}

function installFetch(reply: (path: string) => Response) {
  const mock = vi.fn((input: Parameters<typeof fetch>[0], _init?: RequestInit): Promise<Response> =>
    Promise.resolve(reply(requestPath(input))),
  );
  vi.stubGlobal('fetch', mock);
  return mock;
}

function balancedFetch(failReplies: readonly number[]): MockFetch {
  let variants = 0;
  let failures = 0;
  return installFetch((path) => {
    if (path === '/variant') {
      variants += 1;
      return response(200, variants % 5 === 0 ? 'canary' : 'stable');
    }
    const status = failReplies[failures] ?? failReplies.at(-1) ?? 503;
    failures += 1;
    return response(status);
  });
}

afterEach(() => {
  process.exitCode = undefined;
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('full-profile mesh probe', () => {
  it('samples the 80/20 route and sends bounded IDs through the canary failure path', async () => {
    const stdout = vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const fetchMock = balancedFetch([503, 503]);

    await main({ MESH_PROBE_MODE: 'allowed', MESH_PROBE_TARGET: 'http://mesh-demo.dx03v2:3000' });

    expect(fetchMock).toHaveBeenCalledTimes(402);
    expect(stdout).toHaveBeenCalledWith(
      expect.stringMatching(
        /MESH_PROBE_RESULT total=400 stable=320 canary=80 retry_request_id=mesh_retry_[a-f0-9]{16} isolation_request_id=mesh_isolation_[a-f0-9]{16} fail_status=503/,
      ),
    );
    const failureCalls = fetchMock.mock.calls.filter(([input]) => requestPath(input) === '/fail');
    expect(failureCalls).toHaveLength(2);
    expect((failureCalls[0]?.[1]?.headers as Record<string, string>)['x-lab-probe-id']).toMatch(
      /^mesh_retry_[a-f0-9]{16}$/,
    );
    expect((failureCalls[1]?.[1]?.headers as Record<string, string>)['x-lab-probe-id']).toMatch(
      /^mesh_isolation_[a-f0-9]{16}$/,
    );
  });

  it.each([
    ['a failed variant request', () => response(503), '/variant returned HTTP 503'],
    ['an unknown backend identity', () => response(200, 'unknown'), 'unexpected backend identity unknown'],
  ] as const)('rejects %s', async (_name, variantResponse, message) => {
    const stderr = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    installFetch(() => variantResponse());
    await expect(main({ MESH_PROBE_MODE: 'allowed' })).rejects.toThrow(message);
    expect(stderr).toHaveBeenCalledWith(`mesh-probe: ${message}\n`);
  });

  it.each([
    ['a canary share below the sampling band', 40, '80/20 split was outside the 12–28% sampling band'],
    ['a canary share above the sampling band', 120, '80/20 split was outside the 12–28% sampling band'],
  ] as const)('rejects %s', async (_name, canaryCount, message) => {
    const stderr = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    let variants = 0;
    installFetch((path) => {
      if (path !== '/variant') return response(503);
      variants += 1;
      return response(200, variants <= canaryCount ? 'canary' : 'stable');
    });
    await expect(main({ MESH_PROBE_MODE: 'allowed' })).rejects.toThrow(message);
    expect(stderr).toHaveBeenCalledWith(expect.stringContaining(`mesh-probe: ${message}`));
  });

  it.each([
    [[200], '/fail returned HTTP 200, expected 503'],
    [[503, 200], '/fail after canary ejection returned HTTP 200'],
  ] as const)('rejects an unexpected failure-path response', async (failReplies, message) => {
    const stderr = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    balancedFetch(failReplies);
    await expect(main({ MESH_PROBE_MODE: 'allowed' }, { wait: () => Promise.resolve() })).rejects.toThrow(message);
    expect(stderr).toHaveBeenCalledWith(`mesh-probe: ${message}\n`);
  });

  it('accepts the expected denied response for the intruder identity', async () => {
    const stdout = vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const fetchMock = installFetch((path) => {
      expect(path).toBe('/variant');
      return response(403);
    });
    await main({ MESH_PROBE_MODE: 'intruder' });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(stdout).toHaveBeenCalledWith('MESH_PROBE_DENIED status=403\n');
  });

  it('fails when the intruder is allowed or the probe mode is invalid', async () => {
    const stderr = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
    installFetch(() => response(200, 'stable'));
    await expect(main({ MESH_PROBE_MODE: 'intruder' })).rejects.toThrow(
      'unauthorized identity received HTTP 200, expected 403',
    );
    await expect(main({ MESH_PROBE_MODE: 'typo' })).rejects.toThrow('MESH_PROBE_MODE must be allowed or intruder');
    expect(stderr).toHaveBeenCalledWith('mesh-probe: MESH_PROBE_MODE must be allowed or intruder\n');
  });
});
