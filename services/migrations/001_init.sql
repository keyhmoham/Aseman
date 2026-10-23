# SQL schema migrations.
# The database adapters create tables automatically from the registered models
# (CREATE TABLE IF NOT EXISTS). This file documents the resulting schema for
# PostgreSQL and can be used as a manual bootstrap for existing clusters.

-- Accounts (users and bots).
CREATE TABLE IF NOT EXISTS accounts (
    id              TEXT PRIMARY KEY,          -- universal id (32 hex)
    kind            TEXT NOT NULL,             -- user | bot
    handle          TEXT,
    email           TEXT,
    password_hash   TEXT,
    public_key      TEXT,                      -- Ed25519 identity public key (hex)
    private_key_enc TEXT,                      -- encrypted identity private key
    status          TEXT,
    metadata_id     TEXT,
    last_seen       TIMESTAMPTZ,
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_accounts_handle ON accounts (handle);
CREATE UNIQUE INDEX IF NOT EXISTS uq_accounts_email ON accounts (email);

-- Metadata JSON trees (owner-keyed).
CREATE TABLE IF NOT EXISTS metadatas (
    owner        TEXT PRIMARY KEY,           -- universal id of the owner
    tree         JSONB,
    public_paths JSONB,
    version      BIGINT,
    updated_at   TIMESTAMPTZ
);

-- Spaces and rooms.
CREATE TABLE IF NOT EXISTS spaces (
    id          TEXT PRIMARY KEY,
    owner_id    TEXT,
    name        TEXT,
    description TEXT,
    avatar_id   TEXT,
    metadata_id TEXT,
    public      BOOLEAN,
    created_at  TIMESTAMPTZ,
    updated_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_spaces_owner ON spaces (owner_id);

CREATE TABLE IF NOT EXISTS rooms (
    id          TEXT PRIMARY KEY,
    space_id    TEXT,
    name        TEXT,
    topic       TEXT,
    metadata_id TEXT,
    created_at  TIMESTAMPTZ,
    updated_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_rooms_space ON rooms (space_id);

-- Memberships (space-level rows use the zero room id).
CREATE TABLE IF NOT EXISTS memberships (
    id          TEXT PRIMARY KEY,
    space_id    TEXT,
    room_id     TEXT DEFAULT '00000000000000000000000000000000',
    member_id   TEXT,
    role        TEXT,
    permissions JSONB,
    joined_at   TIMESTAMPTZ,
    created_at  TIMESTAMPTZ,
    updated_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_memberships_space ON memberships (space_id);
CREATE INDEX IF NOT EXISTS idx_memberships_member ON memberships (member_id);

-- Messages, direct messages, files.
CREATE TABLE IF NOT EXISTS messages (
    id         TEXT PRIMARY KEY,
    space_id   TEXT,
    room_id    TEXT,
    sender_id  TEXT,
    body       TEXT,
    mentions   JSONB,
    edited_at  TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_messages_room ON messages (room_id);
-- Upgrade path for existing clusters (idempotent).
ALTER TABLE messages ADD COLUMN IF NOT EXISTS mentions JSONB;

CREATE TABLE IF NOT EXISTS directs (
    id         TEXT PRIMARY KEY,
    from_id    TEXT,
    to_id      TEXT,
    body       TEXT,
    sent_at    TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS files (
    id           TEXT PRIMARY KEY,
    owner_id     TEXT,
    space_id     TEXT,
    room_id      TEXT,
    metadata_id  TEXT,
    meta_path    TEXT,
    name         TEXT,
    mime         TEXT,
    size         BIGINT,
    storage_key  TEXT,
    public       BOOLEAN,
    source_url   TEXT,
    content_hash TEXT,
    created_at   TIMESTAMPTZ,
    updated_at   TIMESTAMPTZ
);

-- Wallets and the distributed ledger.
CREATE TABLE IF NOT EXISTS wallets (
    id         TEXT PRIMARY KEY,
    owner_id   TEXT,
    balance    BIGINT,
    locked     BIGINT,
    updated_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS ledger (
    id          TEXT PRIMARY KEY,
    seq         BIGINT,
    node_id     TEXT,
    type        TEXT,
    from_id     TEXT,
    to_id       TEXT,
    amount      BIGINT,
    description TEXT,
    created_at  TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ledger_seq ON ledger (seq);

-- Bots (VMs).
CREATE TABLE IF NOT EXISTS bots (
    id          TEXT PRIMARY KEY,
    owner_id    TEXT,
    account_id  TEXT,
    name        TEXT,
    vm_type     TEXT,
    status      TEXT,
    vm_id       TEXT,
    image_ref   TEXT,
    spec_yml    TEXT,
    resources   JSONB,
    cost        JSONB,
    pool_id     TEXT,
    started_at  TIMESTAMPTZ,
    stopped_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ,
    updated_at  TIMESTAMPTZ
);

-- Isolated bot key-value store.
CREATE TABLE IF NOT EXISTS kv (
    id         TEXT PRIMARY KEY,
    scope      TEXT,                         -- global | space | room
    scope_id   TEXT,
    owner_id   TEXT,
    key        TEXT,
    value      JSONB,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_kv_scope_owner ON kv (scope, scope_id, owner_id);

-- Sessions, invitations, nodes.
CREATE TABLE IF NOT EXISTS sessions (
    id          TEXT PRIMARY KEY,
    owner_id    TEXT,
    token_hash  TEXT,
    kind        TEXT,
    expires_at  TIMESTAMPTZ,
    last_seen_at TIMESTAMPTZ,
    meta        JSONB,
    created_at  TIMESTAMPTZ,
    updated_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions (token_hash);

CREATE TABLE IF NOT EXISTS invitations (
    id          TEXT PRIMARY KEY,
    space_id    TEXT,
    room_id     TEXT,
    inviter_id  TEXT,
    invitee_id  TEXT,
    role        TEXT,
    token       TEXT,
    status      TEXT,
    expires_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ,
    updated_at  TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS nodes (
    id          TEXT PRIMARY KEY,            -- node id (16 hex)
    url         TEXT,
    public_key  TEXT,
    status      TEXT,
    last_seen   TIMESTAMPTZ,
    is_central  BOOLEAN
);