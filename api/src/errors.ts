// Error model of the API: every failure becomes {"error":{"code","message","requestId"}} with the
// right status. Internal details (stack traces, SQL, driver messages) are logged, never returned.
import { ZodError } from 'zod';

export class HttpError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
  }
}

export interface ErrorBody {
  error: { code: string; message: string; requestId: string };
}

export interface MappedError {
  status: number;
  code: string;
  message: string;
  /** true when the error is unexpected and must be logged at error level. */
  internal: boolean;
}

/** Summarizes zod issues as "field: problem; field: problem" (at most 5 entries). */
export function summarizeIssues(error: ZodError): string {
  const parts = error.issues.slice(0, 5).map((issue) => {
    const path = issue.path.map(String).join('.');
    return path === '' ? issue.message : `${path}: ${issue.message}`;
  });
  if (error.issues.length > 5) {
    parts.push(`and ${error.issues.length - 5} more`);
  }
  return parts.join('; ');
}

// SQLSTATE classes/codes that mean "the database is unavailable", not "the request is wrong".
const DB_UNAVAILABLE_SQLSTATE = /^(08|53|57P0[1-3])/;
const DB_UNAVAILABLE_ERRNO = new Set([
  'ECONNREFUSED',
  'ECONNRESET',
  'ETIMEDOUT',
  'ENOTFOUND',
  'EAI_AGAIN',
  'EHOSTUNREACH',
]);
const DB_UNAVAILABLE_MESSAGE =
  /Connection terminated|timeout exceeded when trying to connect|is not queryable|Query read timeout/i;

export function isDbUnavailable(err: unknown): boolean {
  if (!(err instanceof Error)) {
    return false;
  }
  const code = (err as { code?: unknown }).code;
  if (typeof code === 'string' && (DB_UNAVAILABLE_ERRNO.has(code) || DB_UNAVAILABLE_SQLSTATE.test(code))) {
    return true;
  }
  return DB_UNAVAILABLE_MESSAGE.test(err.message);
}

interface BodyParserError {
  type?: unknown;
  status?: unknown;
}

/** Maps any thrown value to the public error shape. */
export function mapError(err: unknown): MappedError {
  if (err instanceof HttpError) {
    return { status: err.status, code: err.code, message: err.message, internal: false };
  }
  if (err instanceof ZodError) {
    return { status: 400, code: 'validation_error', message: summarizeIssues(err), internal: false };
  }
  const bodyError = (typeof err === 'object' && err !== null ? err : {}) as BodyParserError;
  switch (bodyError.type) {
    case 'entity.parse.failed':
      return { status: 400, code: 'invalid_json', message: 'Request body is not valid JSON', internal: false };
    case 'entity.too.large':
      return { status: 413, code: 'payload_too_large', message: 'Request body exceeds 10 kb', internal: false };
    case 'encoding.unsupported':
    case 'charset.unsupported':
      return {
        status: 415,
        code: 'unsupported_media_type',
        message: 'Request body must be UTF-8 JSON',
        internal: false,
      };
    case 'request.aborted':
    case 'request.size.invalid':
    case 'stream.encoding.set':
    case 'stream.not.readable':
      return { status: 400, code: 'bad_request', message: 'Request body could not be read', internal: false };
    default:
      break;
  }
  if (isDbUnavailable(err)) {
    return { status: 503, code: 'db_unavailable', message: 'Database is unavailable, try again later', internal: true };
  }
  return { status: 500, code: 'internal_error', message: 'Internal server error', internal: true };
}

export function errorBody(code: string, message: string, requestId: string): ErrorBody {
  return { error: { code, message, requestId } };
}
