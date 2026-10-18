import { describe, expect, it } from 'vitest';
import { ApiError, createMessage, deleteMessage, describeError, getInfo, listMessages } from '../api.ts';
import { apiError, INFO, json, mockFetch } from './fetch.ts';

describe('api client', () => {
  it('lists messages with a limit and sends Accept: application/json', async () => {
    const calls = mockFetch(() => json(200, { items: [] }));
    await expect(listMessages(5)).resolves.toEqual([]);
    expect(calls[0]).toMatchObject({ url: '/api/messages?limit=5', headers: { accept: 'application/json' } });
  });

  it('trims the draft before posting', async () => {
    const created = { id: 1, author: 'Ana', text: 'oi', createdAt: '2026-10-10T12:00:00.000Z' };
    const calls = mockFetch(() => json(201, created));
    await expect(createMessage({ author: ' Ana ', text: ' oi ' })).resolves.toEqual(created);
    expect(calls[0]?.body).toEqual({ author: 'Ana', text: 'oi' });
  });

  it('resolves deletes on 204', async () => {
    mockFetch(() => json(204, null));
    await expect(deleteMessage(7, 'token')).resolves.toBeUndefined();
  });

  it('reads /api/info', async () => {
    mockFetch(() => json(200, INFO));
    await expect(getInfo()).resolves.toEqual(INFO);
  });

  it('turns validation errors into a readable message', async () => {
    mockFetch(() => apiError(400, 'validation_error', 'text: must have 1 to 280 characters'));
    const err = await createMessage({ author: 'a', text: 'b' }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err).toMatchObject({
      status: 400,
      code: 'validation_error',
      requestId: 'req-123',
      message: 'Message rejected: text: must have 1 to 280 characters',
    });
  });

  it('keeps unknown API errors and non-JSON bodies understandable', async () => {
    mockFetch(() => apiError(500, 'internal_error', 'Internal server error'));
    await expect(listMessages()).rejects.toMatchObject({ message: 'API error: Internal server error' });

    mockFetch(() => new Response('<html>bad gateway</html>', { status: 502 }));
    await expect(listMessages()).rejects.toMatchObject({
      status: 502,
      code: 'http_error',
      message: 'API error: HTTP 502',
    });
  });

  it('rejects responses with an unexpected shape', async () => {
    mockFetch(() => json(200, { items: [{ id: 'x' }] }));
    await expect(listMessages()).rejects.toMatchObject({ code: 'invalid_response' });
    mockFetch(() => json(201, { ok: true }));
    await expect(createMessage({ author: 'a', text: 'b' })).rejects.toMatchObject({ code: 'invalid_response' });
    mockFetch(() => json(200, { version: 1 }));
    await expect(getInfo()).rejects.toMatchObject({ code: 'invalid_response' });
  });
});

describe('describeError', () => {
  it('adds the request id when there is one', () => {
    expect(describeError(new ApiError(503, 'db_unavailable', 'Banco fora', 'abc'))).toBe(
      'Banco fora (request ID: abc)',
    );
    expect(describeError(new ApiError(0, 'network_error', 'Sem rede'))).toBe('Sem rede');
    expect(describeError(new Error('x'))).toBe('Unexpected error.');
  });
});
