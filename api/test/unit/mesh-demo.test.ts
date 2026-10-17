import { createServer as createTcpServer } from 'node:net';
import { afterEach, describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import { createMeshDemoServer, main } from '../../src/mesh-demo.ts';

afterEach(() => {
  process.exitCode = undefined;
  vi.restoreAllMocks();
});

describe('service mesh exercise backend', () => {
  it('reports the variant and returns a healthy probe', async () => {
    const server = createMeshDemoServer('stable', vi.fn());
    await request(server).get('/healthz').expect(200, { status: 'ok', variant: 'stable' });
    const response = await request(server).get('/variant').expect(200, { variant: 'stable' });
    expect(response.headers['x-lab-variant']).toBe('stable');
  });

  it('returns a deterministic 503 only from the canary fault path', async () => {
    const canary = createMeshDemoServer('canary', vi.fn());
    const failed = await request(canary).get('/fail').set('x-request-id', 'mesh-retry-1').expect(503);
    expect(failed.body).toEqual({ error: 'intentional_canary_failure', variant: 'canary' });

    const stable = createMeshDemoServer('stable', vi.fn());
    await request(stable).get('/fail').expect(200, { variant: 'stable' });
  });

  it('logs only a bounded request identifier for retry counting', async () => {
    const writeLog = vi.fn();
    const server = createMeshDemoServer('canary', writeLog);
    await request(server).get('/fail').set('x-request-id', 'retry id with unsafe chars').expect(503);
    expect(writeLog).toHaveBeenCalledWith(
      'MESH_REQUEST variant=canary path=/fail request_id=retryidwithunsafechars probe_id=',
    );
  });

  it('bounds unknown paths and the mesh probe id in logs', async () => {
    const writeLog = vi.fn();
    const server = createMeshDemoServer('stable', writeLog);
    await request(server)
      .get(`/${'x'.repeat(512)}?password=must-not-be-logged`)
      .set('x-lab-probe-id', `probe ${'y'.repeat(128)}`)
      .expect(404);
    expect(writeLog).toHaveBeenCalledWith(
      `MESH_REQUEST variant=stable path=/unknown request_id=none probe_id=probe${'y'.repeat(59)}`,
    );
  });

  it('rejects non-GET requests and writes request logs by default', async () => {
    const stdout = vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const server = createMeshDemoServer('stable');
    await request(server).post('/variant').expect(405, { error: 'method_not_allowed' });
    expect(stdout).toHaveBeenCalledWith(expect.stringContaining('MESH_REQUEST variant=stable path=/variant'));
  });

  it('validates the entrypoint environment and starts a server on a valid port', async () => {
    const errors = vi.fn();
    expect(main({}, vi.fn(), errors)).toBeUndefined();
    expect(errors).toHaveBeenCalledWith('mesh-demo: MESH_VARIANT must be stable or canary');
    expect(process.exitCode).toBe(1);
    process.exitCode = undefined;

    expect(main({ MESH_VARIANT: 'canary', PORT: '0' }, vi.fn(), errors)).toBeUndefined();
    expect(main({ MESH_VARIANT: 'stable', PORT: '65536' }, vi.fn(), errors)).toBeUndefined();
    expect(errors).toHaveBeenLastCalledWith('mesh-demo: PORT must be a TCP port');

    const reservation = createTcpServer();
    await new Promise<void>((resolve) => reservation.listen(0, '127.0.0.1', resolve));
    const address = reservation.address();
    if (address === null || typeof address === 'string') throw new Error('expected an ephemeral TCP port');
    await new Promise<void>((resolve, reject) => reservation.close((error) => (error ? reject(error) : resolve())));

    const output = vi.fn();
    const server = main({ MESH_VARIANT: 'canary', PORT: String(address.port) }, output, errors);
    expect(server).toBeDefined();
    await new Promise<void>((resolve, reject) => {
      server?.once('listening', resolve);
      server?.once('error', reject);
    });
    expect(output).toHaveBeenCalledWith(`mesh-demo: canary listening on ${address.port}`);
    await new Promise<void>((resolve, reject) => server?.close((error) => (error ? reject(error) : resolve())));
  });
});
