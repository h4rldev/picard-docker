CREATE TABLE users (
  username TEXT PRIMARY KEY,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user' CHECK(role IN ('user','admin','superadmin')),
  auth_version INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER DEFAULT (strftime('%s','now'))
);
