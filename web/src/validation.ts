// Client-side validation that mirrors the API (api/src/validation.ts): trimmed length 1-40 for
// the author, 1-280 for the text, no control characters. The API stays the source of truth.
export const AUTHOR_MAX = 40;
export const TEXT_MAX = 280;

// eslint-disable-next-line no-control-regex -- matching control characters is the point
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/u;

export interface MessageDraft {
  author: string;
  text: string;
}

export type FieldErrors = Partial<Record<keyof MessageDraft, string>>;

function check(value: string, max: number): string | undefined {
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return 'Required field.';
  }
  if (trimmed.length > max) {
    return `Use at most ${max} characters (current: ${trimmed.length}).`;
  }
  if (CONTROL_CHARS.test(trimmed)) {
    return 'Do not use control characters (such as tabs).';
  }
  return undefined;
}

export function validateMessage(draft: MessageDraft): FieldErrors {
  const errors: FieldErrors = {};
  const author = check(draft.author, AUTHOR_MAX);
  const text = check(draft.text, TEXT_MAX);
  if (author !== undefined) {
    errors.author = author;
  }
  if (text !== undefined) {
    errors.text = text;
  }
  return errors;
}
