// Admin authentication for destructive routes: `Authorization: Bearer <ADMIN_TOKEN>`.
// Both sides are hashed first so timingSafeEqual always compares equal-length buffers and the
// comparison time does not depend on where the strings differ or on their lengths.
import { createHash, timingSafeEqual } from 'node:crypto';
import type { RequestHandler } from 'express';
import { HttpError } from '../errors.ts';

const BEARER = /^Bearer ([A-Za-z0-9._~+/=-]+)$/;

function digest(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest();
}

export function tokensMatch(provided: string, expected: string): boolean {
  return timingSafeEqual(digest(provided), digest(expected));
}

export function bearerToken(header: string | undefined): string | undefined {
  if (header === undefined) {
    return undefined;
  }
  return BEARER.exec(header)?.[1];
}

export function requireAdmin(adminToken: string | undefined): RequestHandler {
  return (req, res, next) => {
    if (adminToken === undefined) {
      throw new HttpError(503, 'admin_disabled', 'Admin operations are disabled: ADMIN_TOKEN is not configured');
    }
    const provided = bearerToken(req.get('authorization'));
    if (provided === undefined || !tokensMatch(provided, adminToken)) {
      res.setHeader('WWW-Authenticate', 'Bearer realm="dx03v2"');
      throw new HttpError(401, 'unauthorized', 'A valid admin token is required');
    }
    next();
  };
}
