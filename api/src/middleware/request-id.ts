// Request IDs: an incoming X-Request-Id is reused only when it is short and safe to log;
// anything else is replaced by a fresh UUID. The chosen ID is echoed in the response.
import { randomUUID } from 'node:crypto';

export const REQUEST_ID_HEADER = 'X-Request-Id';

/** The request ID assigned by pino-http (always a string here, see resolveRequestId). */
export function requestIdOf(req: { id?: unknown }): string {
  return typeof req.id === 'string' ? req.id : 'unknown';
}
const SAFE_REQUEST_ID = /^[A-Za-z0-9-]{1,64}$/;

export function resolveRequestId(header: string | string[] | undefined, generate: () => string = randomUUID): string {
  if (typeof header === 'string' && SAFE_REQUEST_ID.test(header)) {
    return header;
  }
  return generate();
}
