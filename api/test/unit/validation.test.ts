import { describe, expect, it } from 'vitest';
import {
  hasControlChars,
  listQuerySchema,
  messageIdSchema,
  messageInputSchema,
  MESSAGE_ID_MAX,
} from '../../src/validation.ts';

describe('messageInputSchema', () => {
  it('trims and keeps the text exactly as typed (no HTML escaping)', () => {
    const parsed = messageInputSchema.parse({ author: '  Ana  ', text: ' <b>oi</b> & "aspas" \'simples\' ' });
    expect(parsed).toEqual({ author: 'Ana', text: '<b>oi</b> & "aspas" \'simples\'' });
  });

  it('accepts the maximum lengths and non-ASCII text', () => {
    const parsed = messageInputSchema.parse({ author: 'á'.repeat(40), text: 'ç'.repeat(280) });
    expect(parsed.author).toHaveLength(40);
    expect(parsed.text).toHaveLength(280);
  });

  it.each([
    [{ author: '', text: 'ok' }, 'author: must have 1 to 40 characters'],
    [{ author: '   ', text: 'ok' }, 'author: must have 1 to 40 characters'],
    [{ author: 'a'.repeat(41), text: 'ok' }, 'author: must have 1 to 40 characters'],
    [{ author: 'Ana', text: 'x'.repeat(281) }, 'text: must have 1 to 280 characters'],
    [{ author: 'Ana' }, 'text: is required'],
    [{ author: 42, text: 'ok' }, 'author: must be a string'],
    [{ author: 'A\u0000na', text: 'ok' }, 'author: must not contain control characters'],
    [{ author: 'Ana', text: 'linha\nquebrada' }, 'text: must not contain control characters'],
    [{ author: 'Ana', text: 'escape \u001b[31m' }, 'text: must not contain control characters'],
    [{ author: 'Ana', text: 'c1 \u0085 char' }, 'text: must not contain control characters'],
  ])('rejects %j', (input, expected) => {
    const result = messageInputSchema.safeParse(input);
    expect(result.success).toBe(false);
    const messages = result.error?.issues.map((issue) => `${issue.path.join('.')}: ${issue.message}`);
    expect(messages).toContain(expected);
  });

  it('rejects unknown fields', () => {
    const result = messageInputSchema.safeParse({ author: 'Ana', text: 'oi', admin: true });
    expect(result.success).toBe(false);
    expect(result.error?.issues[0]?.code).toBe('unrecognized_keys');
  });

  it.each([null, 'text', ['a'], 3])('rejects a non-object body (%j)', (body) => {
    const result = messageInputSchema.safeParse(body);
    expect(result.error?.issues[0]?.message).toBe('body must be a JSON object with author and text');
  });
});

describe('hasControlChars', () => {
  it('flags C0, DEL and C1 but not printable Unicode', () => {
    expect(hasControlChars('\t')).toBe(true);
    expect(hasControlChars('\u007f')).toBe(true);
    expect(hasControlChars('\u009f')).toBe(true);
    expect(hasControlChars('olá, mundo 👋')).toBe(false);
  });
});

describe('listQuerySchema', () => {
  it('defaults to 20', () => {
    expect(listQuerySchema.parse({})).toEqual({ limit: 20 });
  });

  it.each(['1', '20', '100'])('accepts limit=%s', (limit) => {
    expect(listQuerySchema.parse({ limit }).limit).toBe(Number(limit));
  });

  it.each(['0', '101', '-1', '1.5', 'abc', '', '1e2', ' 5'])('rejects limit=%j', (limit) => {
    expect(listQuerySchema.safeParse({ limit }).success).toBe(false);
  });

  it('rejects a repeated parameter', () => {
    expect(listQuerySchema.safeParse({ limit: ['1', '2'] }).success).toBe(false);
  });
});

describe('messageIdSchema', () => {
  it.each(['1', '42', String(MESSAGE_ID_MAX)])('accepts %s', (id) => {
    expect(messageIdSchema.parse(id)).toBe(Number(id));
  });

  it.each(['0', '-1', '01', 'abc', '1.0', String(MESSAGE_ID_MAX + 1), '99999999999'])('rejects %s', (id) => {
    expect(messageIdSchema.safeParse(id).success).toBe(false);
  });
});
