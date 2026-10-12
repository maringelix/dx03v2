// JSON body handling for write routes: 415 for a body that is not JSON, 10 kb limit (413 above),
// malformed JSON becomes a 400 in the error handler (errors.ts maps the body-parser error types).
import express, { type RequestHandler } from 'express';
import { HttpError } from '../errors.ts';

export const BODY_LIMIT = '10kb';

export const requireJson: RequestHandler = (req, _res, next) => {
  // req.is() is null when there is no body at all: that case is a validation error (400).
  if (req.is('application/json') === false) {
    throw new HttpError(415, 'unsupported_media_type', 'Content-Type must be application/json');
  }
  next();
};

export const jsonBody: RequestHandler = express.json({ limit: BODY_LIMIT, strict: true, type: 'application/json' });
