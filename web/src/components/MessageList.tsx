import type { Message } from '../api.ts';

interface Props {
  items: Message[];
  loading: boolean;
  /** Delete buttons are rendered only in admin mode. */
  adminMode: boolean;
  onDelete: (message: Message) => void;
}

const dateFormat = new Intl.DateTimeFormat('en-US', { dateStyle: 'short', timeStyle: 'short' });

export function MessageList({ items, loading, adminMode, onDelete }: Props) {
  if (loading) {
    return <p className="muted">Loading messages…</p>;
  }
  if (items.length === 0) {
    return <p className="muted">No messages yet. Be the first to write one.</p>;
  }
  return (
    <ol className="messages">
      {items.map((message) => (
        <li key={message.id}>
          <article className="message" aria-labelledby={`message-${message.id}-author`}>
            <header className="message-header">
              <strong id={`message-${message.id}-author`}>{message.author}</strong>
              <time dateTime={message.createdAt}>{dateFormat.format(new Date(message.createdAt))}</time>
            </header>
            {/* Rendered as text: React escapes it, so stored markup shows up literally. */}
            <p className="message-text">{message.text}</p>
            {adminMode && (
              <button
                type="button"
                className="button danger"
                aria-label={`Delete message by ${message.author}`}
                onClick={() => {
                  onDelete(message);
                }}
              >
                Delete
              </button>
            )}
          </article>
        </li>
      ))}
    </ol>
  );
}
