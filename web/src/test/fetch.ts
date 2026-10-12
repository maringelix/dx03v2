// Test double for window.fetch: each test describes the API responses it needs.
import { vi } from 'vitest';

export interface FetchCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}

export type Handler = (call: FetchCall) => Response | Promise<Response>;

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(status === 204 ? null : JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  });
}

export function apiError(status: number, code: string, message: string, requestId = 'req-123'): Response {
  return json(status, { error: { code, message, requestId } });
}

export const INFO = {
  name: 'dx03v2-api',
  version: '2.0.0',
  commit: '0123456789abcdef0123456789abcdef01234567',
  environment: 'kind',
  uptimeSeconds: 12,
};

/** Installs a fetch mock and returns the list of calls it received. */
export function mockFetch(handler: Handler): FetchCall[] {
  const calls: FetchCall[] = [];
  const fake = vi.fn(async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const headers = Object.fromEntries(new Headers(init.headers).entries());
    const raw = typeof init.body === 'string' ? init.body : undefined;
    const call: FetchCall = {
      url: typeof input === 'string' ? input : input instanceof URL ? input.href : input.url,
      method: init.method ?? 'GET',
      headers,
      body: raw === undefined ? undefined : (JSON.parse(raw) as unknown),
    };
    calls.push(call);
    return handler(call);
  });
  vi.stubGlobal('fetch', fake);
  return calls;
}
