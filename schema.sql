PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS biome_sessions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    biome_id        TEXT NOT NULL,
    started_at      INTEGER NOT NULL,
    ended_at        INTEGER
);
CREATE INDEX IF NOT EXISTS idx_biome_sessions_active
    ON biome_sessions(ended_at) WHERE ended_at IS NULL;

CREATE TABLE IF NOT EXISTS encounters (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      INTEGER NOT NULL REFERENCES biome_sessions(id),
    encountered_at  INTEGER NOT NULL,
    species         TEXT NOT NULL,
    dex_id          INTEGER NOT NULL,
    level           INTEGER NOT NULL,
    nature          TEXT NOT NULL,
    ability         TEXT NOT NULL,
    is_hidden_ability INTEGER NOT NULL,
    gender          TEXT NOT NULL,
    shiny           INTEGER NOT NULL,
    held_berry      TEXT,
    friendship      INTEGER NOT NULL DEFAULT 70,
    iv_hp INTEGER, iv_atk INTEGER, iv_def INTEGER,
    iv_spa INTEGER, iv_spd INTEGER, iv_spe INTEGER,
    ev_hp INTEGER, ev_atk INTEGER, ev_def INTEGER,
    ev_spa INTEGER, ev_spd INTEGER, ev_spe INTEGER,
    stat_hp INTEGER, stat_atk INTEGER, stat_def INTEGER,
    stat_spa INTEGER, stat_spd INTEGER, stat_spe INTEGER,
    moves_json      TEXT NOT NULL,
    sprite_path     TEXT
);
CREATE INDEX IF NOT EXISTS idx_enc_session ON encounters(session_id);
CREATE INDEX IF NOT EXISTS idx_enc_shiny   ON encounters(shiny) WHERE shiny=1;
CREATE INDEX IF NOT EXISTS idx_enc_species ON encounters(species);
CREATE INDEX IF NOT EXISTS idx_enc_time    ON encounters(encountered_at);

CREATE TABLE IF NOT EXISTS item_drops (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      INTEGER NOT NULL REFERENCES biome_sessions(id),
    encountered_at  INTEGER NOT NULL,
    item            TEXT NOT NULL,
    sprite_path     TEXT
);
CREATE INDEX IF NOT EXISTS idx_item_session ON item_drops(session_id);
CREATE INDEX IF NOT EXISTS idx_item_time    ON item_drops(encountered_at);

CREATE TABLE IF NOT EXISTS daemon_state (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
