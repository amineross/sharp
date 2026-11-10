-- One row per Sharp install. The id is a random UUID made on the Mac.
CREATE TABLE IF NOT EXISTS sharp_installs (
  id TEXT PRIMARY KEY,
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  version TEXT,
  macos TEXT,
  model TEXT,
  role TEXT,
  link TEXT,
  display TEXT,
  mode TEXT,
  resolution TEXT,
  country TEXT
);
CREATE INDEX IF NOT EXISTS sharp_installs_last_seen ON sharp_installs(last_seen);
