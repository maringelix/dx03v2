import { describe, expect, it } from 'vitest';
import { validateMessage } from '../validation.ts';

describe('validateMessage (mirrors the API limits)', () => {
  it('accepts trimmed values within the limits', () => {
    expect(validateMessage({ author: ' Ana ', text: 'x'.repeat(280) })).toEqual({});
    expect(validateMessage({ author: 'a'.repeat(40), text: 'olá 👋' })).toEqual({});
  });

  it('requires both fields after trimming', () => {
    expect(validateMessage({ author: '   ', text: '' })).toEqual({
      author: 'Campo obrigatório.',
      text: 'Campo obrigatório.',
    });
  });

  it('enforces the maximum lengths', () => {
    expect(validateMessage({ author: 'a'.repeat(41), text: 'x'.repeat(281) })).toEqual({
      author: 'Use no máximo 40 caracteres (agora: 41).',
      text: 'Use no máximo 280 caracteres (agora: 281).',
    });
  });

  it.each(['tab\there', 'nul\u0000', 'del\u007f', 'c1\u0085', 'quebra\nde linha'])('rejects %j', (text) => {
    expect(validateMessage({ author: 'Ana', text }).text).toBe('Não use caracteres de controle (como tabulação).');
  });
});
