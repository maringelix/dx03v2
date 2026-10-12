// Message queries (parameterized only). The column is `body`; the API field is `text`.
import type { DbPool } from './db.ts';
import type { MessageInput } from './validation.ts';

export interface Message {
  id: number;
  author: string;
  text: string;
  createdAt: string;
}

interface MessageRow {
  id: number;
  author: string;
  body: string;
  created_at: Date;
}

const COLUMNS = 'id, author, body, created_at';

function toMessage(row: MessageRow): Message {
  return { id: row.id, author: row.author, text: row.body, createdAt: row.created_at.toISOString() };
}

export async function listMessages(pool: DbPool, limit: number): Promise<Message[]> {
  const result = await pool.query<MessageRow>(
    `SELECT ${COLUMNS} FROM messages ORDER BY created_at DESC, id DESC LIMIT $1`,
    [limit],
  );
  return result.rows.map(toMessage);
}

export async function createMessage(pool: DbPool, input: MessageInput): Promise<Message> {
  const result = await pool.query<MessageRow>(
    `INSERT INTO messages (author, body) VALUES ($1, $2) RETURNING ${COLUMNS}`,
    [input.author, input.text],
  );
  const row = result.rows[0];
  if (row === undefined) {
    throw new Error('INSERT returned no row');
  }
  return toMessage(row);
}

export async function deleteMessage(pool: DbPool, id: number): Promise<boolean> {
  const result = await pool.query('DELETE FROM messages WHERE id = $1', [id]);
  return result.rowCount === 1;
}

export async function countMessages(pool: DbPool): Promise<number> {
  const result = await pool.query<{ count: number }>('SELECT count(*)::integer AS count FROM messages');
  return result.rows[0]?.count ?? 0;
}
