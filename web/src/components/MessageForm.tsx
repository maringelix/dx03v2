import { useState, type FormEvent } from 'react';
import { AUTHOR_MAX, TEXT_MAX, validateMessage, type FieldErrors, type MessageDraft } from '../validation.ts';

interface Props {
  /** Resolves true when the message was published (the form is then cleared). */
  onSubmit: (draft: MessageDraft) => Promise<boolean>;
}

const EMPTY: MessageDraft = { author: '', text: '' };

export function MessageForm({ onSubmit }: Props) {
  const [draft, setDraft] = useState<MessageDraft>(EMPTY);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [submitting, setSubmitting] = useState(false);

  const update = (field: keyof MessageDraft) => (value: string) => {
    setDraft((current) => ({ ...current, [field]: value }));
    if (errors[field] !== undefined) {
      setErrors((current) => ({ ...current, [field]: undefined }));
    }
  };

  const handleSubmit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const found = validateMessage(draft);
    setErrors(found);
    if (found.author !== undefined || found.text !== undefined) {
      return;
    }
    setSubmitting(true);
    const published = await onSubmit(draft);
    setSubmitting(false);
    if (published) {
      setDraft(EMPTY);
    }
  };

  return (
    <form className="message-form" noValidate onSubmit={(event) => void handleSubmit(event)}>
      <Field
        id="author"
        label="Your name"
        hint={`1 to ${AUTHOR_MAX} characters (${draft.author.trim().length}/${AUTHOR_MAX}).`}
        value={draft.author}
        error={errors.author}
        autoComplete="nickname"
        onChange={update('author')}
      />
      <Field
        id="text"
        label="Message"
        hint={`1 to ${TEXT_MAX} characters (${draft.text.trim().length}/${TEXT_MAX}).`}
        value={draft.text}
        error={errors.text}
        autoComplete="off"
        onChange={update('text')}
      />
      <button type="submit" className="button primary" disabled={submitting}>
        {submitting ? 'Publishing…' : 'Publish'}
      </button>
    </form>
  );
}

interface FieldProps {
  id: string;
  label: string;
  hint: string;
  value: string;
  error: string | undefined;
  autoComplete: string;
  onChange: (value: string) => void;
}

function Field({ id, label, hint, value, error, autoComplete, onChange }: FieldProps) {
  const hintId = `${id}-hint`;
  const errorId = `${id}-error`;
  return (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      <input
        id={id}
        name={id}
        type="text"
        value={value}
        autoComplete={autoComplete}
        aria-invalid={error !== undefined}
        aria-describedby={error !== undefined ? `${hintId} ${errorId}` : hintId}
        onChange={(event) => {
          onChange(event.target.value);
        }}
      />
      <p id={hintId} className="hint">
        {hint}
      </p>
      {error !== undefined && (
        <p id={errorId} className="field-error">
          {error}
        </p>
      )}
    </div>
  );
}
