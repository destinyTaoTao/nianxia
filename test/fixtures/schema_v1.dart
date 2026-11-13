// Frozen v1 schema mirrored from schema_v1.sql for Android integration fixtures.
const schemaV1Fixture = r'''
-- Frozen schema shipped before schema-v2 storage isolation.
PRAGMA user_version = 1;
CREATE TABLE records (
 id TEXT PRIMARY KEY, parent_id TEXT REFERENCES records(id) ON DELETE CASCADE,
 body TEXT NOT NULL, created_at TEXT NOT NULL, timezone TEXT NOT NULL,
 offset_minutes INTEGER NOT NULL, revision INTEGER NOT NULL,
 favorite INTEGER NOT NULL, audio TEXT, duration_ms INTEGER NOT NULL,
 transcript TEXT, transcription TEXT NOT NULL, organization TEXT,
 organization_revision INTEGER, vector TEXT, vector_revision INTEGER);
CREATE INDEX records_parent ON records(parent_id);
CREATE TABLE restored (fingerprint TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE);
CREATE TABLE metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL);
INSERT INTO records VALUES ('parent',NULL,'原文不改写','2026-11-01T01:02:03.456Z','Asia/Shanghai',480,7,1,'original.wav',1234,'原始转写','done','{"title":"整理"}',7,'[0.1,0.2,0.3]',7);
INSERT INTO records VALUES ('child','parent','追加','2026-11-01T02:02:03.456Z','Asia/Shanghai',480,2,0,NULL,0,NULL,'none','broken',2,'[1,"bad"]',2);
INSERT INTO restored VALUES ('frozen-hash','parent');
INSERT INTO metadata VALUES ('theme_mode','dark');
INSERT INTO metadata VALUES ('search_model','fixture-model');
''';
