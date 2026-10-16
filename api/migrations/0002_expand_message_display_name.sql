-- R7.2 expand phase: old releases keep inserting only author/body, so this additive nullable field
-- does not break a rolling upgrade or an application rollback. Do not contract it until the rollback
-- window has closed and every older image has been retired.
ALTER TABLE messages
  ADD COLUMN display_name text
  CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 40);
