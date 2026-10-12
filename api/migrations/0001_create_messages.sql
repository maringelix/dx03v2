-- Message board. Text is stored exactly as the API received it (after trimming); the length
-- checks mirror the API limits as a second line of defence.
CREATE TABLE messages (
  id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  author text NOT NULL CHECK (char_length(author) BETWEEN 1 AND 40),
  body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 280),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX messages_created_at_id_idx ON messages (created_at DESC, id DESC);
