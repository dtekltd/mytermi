-- Plans: limits an admin can assign to users (no payments yet).
CREATE TABLE plans (
    id           text PRIMARY KEY,
    name         text        NOT NULL,
    description  text        NOT NULL DEFAULT '',
    max_devices  integer     NOT NULL DEFAULT 0,   -- 0 = unlimited
    sync_enabled boolean     NOT NULL DEFAULT true,
    is_default   boolean     NOT NULL DEFAULT false, -- plan for new users (exactly one)
    sort_order   integer     NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX plans_one_default ON plans (is_default) WHERE is_default;

INSERT INTO plans (id, name, description, max_devices, sync_enabled, is_default, sort_order) VALUES
    ('free', 'Free', 'Sync tối đa 2 thiết bị', 2, true, true, 0),
    ('pro',  'Pro',  'Không giới hạn thiết bị', 0, true, false, 1);

CREATE TABLE users (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email          text        NOT NULL,          -- always lower-cased
    email_verified boolean     NOT NULL DEFAULT false,
    password_hash  text,                          -- argon2id, NULL until the user sets one
    name           text        NOT NULL DEFAULT '',
    role           text        NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
    plan_id        text        NOT NULL REFERENCES plans (id),
    disabled       boolean     NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    last_seen_at   timestamptz
);
CREATE UNIQUE INDEX users_email ON users (email);

-- Sign in with Google / Apple accounts linked to a user.
CREATE TABLE identities (
    provider   text        NOT NULL CHECK (provider IN ('google', 'apple')),
    subject    text        NOT NULL,
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    email      text        NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, subject)
);
CREATE INDEX identities_user ON identities (user_id);

-- One-time codes sent by email (sign up / sign in / password reset).
CREATE TABLE email_codes (
    id          bigserial PRIMARY KEY,
    email       text        NOT NULL,
    code_hash   bytea       NOT NULL,
    attempts    integer     NOT NULL DEFAULT 0,
    expires_at  timestamptz NOT NULL,
    consumed_at timestamptz,
    ip          text        NOT NULL DEFAULT '',
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX email_codes_email ON email_codes (email, created_at DESC);

-- Refresh-token sessions (one per signed-in device, or console login).
CREATE TABLE sessions (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind         text        NOT NULL DEFAULT 'app' CHECK (kind IN ('app', 'console')),
    token_hash   bytea       NOT NULL,
    auth_method  text        NOT NULL,            -- email_code | password | google | apple
    device_id    text        NOT NULL DEFAULT '',   -- stable per install (app keychain)
    device_name  text        NOT NULL DEFAULT '',
    platform     text        NOT NULL DEFAULT '',
    ip           text        NOT NULL DEFAULT '',
    user_agent   text        NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    revoked_at   timestamptz
);
CREATE UNIQUE INDEX sessions_token ON sessions (token_hash);
CREATE INDEX sessions_user ON sessions (user_id);

-- End-to-end encrypted vault: the server only stores wrapped keys and ciphertext.
CREATE TABLE vaults (
    user_id              uuid PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    -- new value every time a vault is created (after a reset old devices must re-unlock)
    generation           bigint      NOT NULL DEFAULT (extract(epoch FROM clock_timestamp()) * 1000)::bigint,
    rev                  bigint      NOT NULL DEFAULT 0, -- last item revision handed out
    kdf                  jsonb       NOT NULL,           -- {"alg":"argon2id","m":65536,"t":3,"p":1}
    salt                 bytea       NOT NULL,
    wrapped_key          bytea       NOT NULL,           -- vault key sealed with the vault password
    recovery_wrapped_key bytea       NOT NULL,           -- vault key sealed with the recovery key
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE vault_items (
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    id          uuid        NOT NULL,
    type        text        NOT NULL,          -- host | key | snippet | known_host
    rev         bigint      NOT NULL,
    modified_at timestamptz NOT NULL,          -- client clock, for last-writer-wins
    deleted     boolean     NOT NULL DEFAULT false,
    data        bytea,                         -- ciphertext; NULL for tombstones
    PRIMARY KEY (user_id, id)
);
CREATE INDEX vault_items_rev ON vault_items (user_id, rev);

-- Server configuration editable from the console (SMTP, sign-in providers...).
CREATE TABLE settings (
    key        text PRIMARY KEY,
    value      jsonb       NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
    id         bigserial PRIMARY KEY,
    at         timestamptz NOT NULL DEFAULT now(),
    actor_id   uuid,
    action     text        NOT NULL,
    target     text        NOT NULL DEFAULT '',
    meta       jsonb       NOT NULL DEFAULT '{}',
    ip         text        NOT NULL DEFAULT ''
);
CREATE INDEX audit_log_at ON audit_log (at DESC);
