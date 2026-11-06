-- Notes mirrored from the Riff Pocket iPhone app (one-way: phone → connector).
CREATE TABLE IF NOT EXISTS notes (
  id               TEXT PRIMARY KEY,
  title            TEXT NOT NULL,
  created_at       REAL NOT NULL,
  updated_at       REAL NOT NULL,
  duration         REAL NOT NULL DEFAULT 0,
  source           TEXT,
  plaud_id         TEXT,
  folder_id        TEXT,
  summary          TEXT,
  transcript_text  TEXT,   -- "[hh:mm:ss] Speaker: text" lines, for search and get_note
  attachments_text TEXT,   -- text extracted from attached files
  doc              TEXT NOT NULL  -- the full note as the phone sent it (JSON)
);
CREATE INDEX IF NOT EXISTS notes_created ON notes (created_at DESC);
CREATE INDEX IF NOT EXISTS notes_plaud ON notes (plaud_id);

CREATE TABLE IF NOT EXISTS folders (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  updated_at REAL NOT NULL
);

-- e.g. key 'plaud' → {"userToken", "apiBase", "workspaceId"} sent from the phone.
CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
