// Same-origin client of the dx03v2 API (/api is routed to the API by nginx or by Application
// Gateway for Containers).
// Responses are checked before use; every failure becomes an ApiError with an English message.

export interface Message {
  id: number;
  author: string;
  text: string;
  createdAt: string;
}

export interface ApiInfo {
  name: string;
  version: string;
  commit: string;
  environment: string;
  uptimeSeconds: number;
}

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly requestId: string | undefined;

  constructor(status: number, code: string, message: string, requestId?: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.requestId = requestId;
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null;

export function isMessage(value: unknown): value is Message {
  return (
    isRecord(value) &&
    typeof value.id === 'number' &&
    typeof value.author === 'string' &&
    typeof value.text === 'string' &&
    typeof value.createdAt === 'string'
  );
}

function isInfo(value: unknown): value is ApiInfo {
  return (
    isRecord(value) &&
    typeof value.version === 'string' &&
    typeof value.commit === 'string' &&
    typeof value.environment === 'string'
  );
}

const FRIENDLY: Record<string, string> = {
  rate_limited: 'Too many messages. Wait a minute and try again.',
  unauthorized: 'Invalid admin token.',
  admin_disabled: 'Admin mode is disabled in this installation (no ADMIN_TOKEN).',
  db_unavailable: 'The database is unavailable. Try again shortly.',
  not_found: 'The message no longer exists.',
};

function errorFrom(status: number, body: unknown): ApiError {
  const detail = isRecord(body) && isRecord(body.error) ? body.error : {};
  const code = typeof detail.code === 'string' ? detail.code : 'http_error';
  const requestId = typeof detail.requestId === 'string' ? detail.requestId : undefined;
  const apiMessage = typeof detail.message === 'string' ? detail.message : `HTTP ${status}`;
  const message =
    FRIENDLY[code] ?? (code === 'validation_error' ? `Message rejected: ${apiMessage}` : `API error: ${apiMessage}`);
  return new ApiError(status, code, message, requestId);
}

async function call(path: string, init: RequestInit = {}): Promise<unknown> {
  let response: Response;
  try {
    response = await fetch(path, { ...init, headers: { Accept: 'application/json', ...init.headers } });
  } catch {
    throw new ApiError(0, 'network_error', 'Could not reach the API. Check your connection.');
  }
  if (response.status === 204) {
    return undefined;
  }
  const body: unknown = await response.json().catch(() => undefined);
  if (!response.ok) {
    throw errorFrom(response.status, body);
  }
  return body;
}

function invalidResponse(): ApiError {
  return new ApiError(502, 'invalid_response', 'The API returned an unexpected response format.');
}

export async function listMessages(limit = 50): Promise<Message[]> {
  const body = await call(`/api/messages?limit=${limit}`);
  if (!isRecord(body) || !Array.isArray(body.items) || !body.items.every(isMessage)) {
    throw invalidResponse();
  }
  return body.items;
}

export async function createMessage(draft: { author: string; text: string }): Promise<Message> {
  const body = await call('/api/messages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ author: draft.author.trim(), text: draft.text.trim() }),
  });
  if (!isMessage(body)) {
    throw invalidResponse();
  }
  return body;
}

export async function deleteMessage(id: number, adminToken: string): Promise<void> {
  await call(`/api/messages/${id}`, { method: 'DELETE', headers: { Authorization: `Bearer ${adminToken}` } });
}

export async function getInfo(): Promise<ApiInfo> {
  const body = await call('/api/info');
  if (!isInfo(body)) {
    throw invalidResponse();
  }
  return body;
}

/** User-facing text for any error, with the request ID when the API sent one. */
export function describeError(err: unknown): string {
  if (err instanceof ApiError) {
    return err.requestId ? `${err.message} (request ID: ${err.requestId})` : err.message;
  }
  return 'Unexpected error.';
}
