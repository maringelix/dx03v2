// Per-client write rate limit. The key is `req.ip`, which Express derives from X-Forwarded-For
// using `trust proxy = TRUST_PROXY_HOPS`: only the entries appended by trusted proxies count, so
// a client cannot pick its own identity by sending spoofed leftmost entries.
// The counter lives in memory, per process: with N replicas the effective limit is up to N times
// higher (documented in docs/ARCHITECTURE.md).
import type { RequestHandler } from 'express';
import { rateLimit } from 'express-rate-limit';
import { errorBody } from '../errors.ts';
import { requestIdOf } from './request-id.ts';

export const WRITE_WINDOW_MS = 60_000;

export function writeRateLimiter(limitPerMinute: number): RequestHandler {
  return rateLimit({
    windowMs: WRITE_WINDOW_MS,
    limit: limitPerMinute,
    // RateLimit-Policy/RateLimit headers (IETF draft 8); the library also sets Retry-After on 429.
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    identifier: 'writes',
    handler: (req, res) => {
      res
        .status(429)
        .json(errorBody('rate_limited', 'Too many write requests from this client, retry later', requestIdOf(req)));
    },
  });
}
