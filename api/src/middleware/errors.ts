// Last two handlers of the app: unknown routes and the JSON error mapper.
import type { ErrorRequestHandler, RequestHandler } from 'express';
import { errorBody, mapError } from '../errors.ts';
import { requestIdOf } from './request-id.ts';

export const notFound: RequestHandler = (req, res) => {
  res.status(404).json(errorBody('not_found', 'Route not found', requestIdOf(req)));
};

export const errorHandler: ErrorRequestHandler = (err: unknown, req, res, next) => {
  const mapped = mapError(err);
  if (mapped.internal) {
    req.log.error({ err }, 'request failed');
  }
  if (res.headersSent) {
    next(err);
    return;
  }
  res.status(mapped.status).json(errorBody(mapped.code, mapped.message, requestIdOf(req)));
};
