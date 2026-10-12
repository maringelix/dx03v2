// Message board routes: list, create (rate limited per client IP), delete (admin token), stats.
import express, { type Router } from 'express';
import type { Config } from '../config.ts';
import type { DbPool } from '../db.ts';
import { HttpError } from '../errors.ts';
import { trackRoute } from '../metrics.ts';
import { requireAdmin } from '../middleware/admin-auth.ts';
import { jsonBody, requireJson } from '../middleware/json-body.ts';
import { writeRateLimiter } from '../middleware/rate-limit.ts';
import { countMessages, createMessage, deleteMessage, listMessages } from '../repository.ts';
import { listQuerySchema, messageIdSchema, messageInputSchema } from '../validation.ts';

export function messagesRouter(config: Config, pool: DbPool): Router {
  const router = express.Router();
  const writeLimit = writeRateLimiter(config.rateLimitWritePerMinute);
  const adminOnly = requireAdmin(config.adminToken);

  router.get('/messages', trackRoute, async (req, res) => {
    const { limit } = listQuerySchema.parse(req.query);
    res.json({ items: await listMessages(pool, limit) });
  });

  // The limiter runs before parsing and validation: rejected writes also count.
  router.post('/messages', trackRoute, writeLimit, requireJson, jsonBody, async (req, res) => {
    const input = messageInputSchema.parse(req.body);
    const message = await createMessage(pool, input);
    res.status(201).location(`/api/messages/${message.id}`).json(message);
  });

  router.delete('/messages/:id', trackRoute, adminOnly, async (req, res) => {
    const id = messageIdSchema.parse(req.params.id);
    if (!(await deleteMessage(pool, id))) {
      throw new HttpError(404, 'not_found', 'Message not found');
    }
    res.status(204).end();
  });

  router.get('/stats', trackRoute, async (_req, res) => {
    res.json({ messages: await countMessages(pool) });
  });

  return router;
}
