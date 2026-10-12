// Input validation. Text is stored exactly as received after trimming: no HTML escaping (the web
// UI renders text as text). Control characters (C0, DEL, C1) are rejected instead of stripped.
import { z } from 'zod';

export const AUTHOR_MAX = 40;
export const TEXT_MAX = 280;
export const LIST_LIMIT_DEFAULT = 20;
export const LIST_LIMIT_MAX = 100;
/** Messages use an `integer` primary key; larger ids can never exist. */
export const MESSAGE_ID_MAX = 2147483647;

// eslint-disable-next-line no-control-regex -- matching control characters is the point
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/u;

export function hasControlChars(value: string): boolean {
  return CONTROL_CHARS.test(value);
}

const boundedText = (max: number) =>
  z
    .string({ error: (issue) => (issue.input === undefined ? 'is required' : 'must be a string') })
    .trim()
    .min(1, `must have 1 to ${max} characters`)
    .max(max, `must have 1 to ${max} characters`)
    .refine((value) => !hasControlChars(value), 'must not contain control characters');

export const messageInputSchema = z.strictObject(
  {
    author: boundedText(AUTHOR_MAX),
    text: boundedText(TEXT_MAX),
  },
  {
    error: (issue) => (issue.code === 'invalid_type' ? 'body must be a JSON object with author and text' : undefined),
  },
);

export type MessageInput = z.infer<typeof messageInputSchema>;

const limitMessage = `must be an integer between 1 and ${LIST_LIMIT_MAX}`;

export const listQuerySchema = z.object({
  limit: z
    .string({ error: limitMessage })
    .regex(/^[0-9]{1,3}$/, limitMessage)
    .transform(Number)
    .pipe(z.number().int().min(1, limitMessage).max(LIST_LIMIT_MAX, limitMessage))
    .optional()
    .transform((value) => value ?? LIST_LIMIT_DEFAULT),
});

export const messageIdSchema = z
  .string()
  .regex(/^[1-9][0-9]{0,9}$/, 'must be a positive integer')
  .transform(Number)
  .pipe(z.number().int().positive().max(MESSAGE_ID_MAX, 'must be a positive integer'));
