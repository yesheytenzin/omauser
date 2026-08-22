-- D1 schema for Omauser (optional, for >1k users)
-- Run: wrangler d1 create omauser && wrangler d1 execute omauser --file schema.sql
-- Then add to wrangler.toml: [[d1_databases]] binding="DB" database_name="omauser" database_id="..."
CREATE TABLE IF NOT EXISTS devices (
  hash TEXT PRIMARY KEY,
  country TEXT NOT NULL,
  lastSeen INTEGER NOT NULL,
  firstSeen INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS stats (
  id INTEGER PRIMARY KEY CHECK (id=1),
  total INTEGER NOT NULL,
  active30d INTEGER NOT NULL,
  byCountry TEXT NOT NULL,
  updatedAt INTEGER NOT NULL
);
INSERT OR IGNORE INTO stats(id,total,active30d,byCountry,updatedAt) VALUES(1,0,0,'{}',0);
CREATE INDEX IF NOT EXISTS idx_devices_lastSeen ON devices(lastSeen);
CREATE INDEX IF NOT EXISTS idx_devices_country ON devices(country);
