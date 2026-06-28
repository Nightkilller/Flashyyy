-- Flashy Signaling Server — Database Schema
-- This schema is used by the signaling server to manage users, devices,
-- pairings, and authentication. See docs/ARCHITECTURE.md for details.

-- One row per email account (created on first successful email verification)
CREATE TABLE users (
    id              TEXT PRIMARY KEY,         -- UUID
    email           TEXT UNIQUE NOT NULL,
    display_name    TEXT,
    created_at      TIMESTAMP DEFAULT (datetime('now'))
);

-- One row per physical device install (whether or not it's linked to a user)
CREATE TABLE devices (
    id              TEXT PRIMARY KEY,         -- UUID, generated on first app launch
    user_id         TEXT REFERENCES users(id) NULL,  -- NULL until linked via email login
    public_key      TEXT NOT NULL,            -- device's long-term public key (set at creation)
    device_name     TEXT NOT NULL,            -- e.g. "Aditya's MacBook"
    device_type     TEXT NOT NULL,            -- mobile | desktop | web
    last_seen_at    TIMESTAMP,
    created_at      TIMESTAMP DEFAULT (datetime('now'))
);

-- Records a successful QR pairing between two devices (independent of any user_id)
CREATE TABLE pairings (
    id              TEXT PRIMARY KEY,
    device_a_id     TEXT REFERENCES devices(id),
    device_b_id     TEXT REFERENCES devices(id),
    paired_at       TIMESTAMP DEFAULT (datetime('now'))
);

-- Short-lived, single-use tokens encoded into QR codes
CREATE TABLE pairing_tokens (
    token           TEXT PRIMARY KEY,
    device_id       TEXT REFERENCES devices(id),  -- device that generated the QR
    expires_at      TIMESTAMP NOT NULL,            -- created_at + ~2 minutes
    used            INTEGER DEFAULT 0              -- boolean (SQLite has no BOOLEAN type)
);

-- Short-lived codes sent to email for login verification
CREATE TABLE email_verification_codes (
    email           TEXT NOT NULL,
    code            TEXT NOT NULL,              -- 6-digit, hashed before storing
    expires_at      TIMESTAMP NOT NULL,          -- ~10 minutes
    used            INTEGER DEFAULT 0,           -- boolean
    PRIMARY KEY (email, code)
);

-- Long-lived session tokens issued to a device after successful email verification
CREATE TABLE sessions (
    token           TEXT PRIMARY KEY,
    device_id       TEXT REFERENCES devices(id),
    user_id         TEXT REFERENCES users(id),
    expires_at      TIMESTAMP NOT NULL,
    created_at      TIMESTAMP DEFAULT (datetime('now'))
);

-- Indexes for common queries
CREATE INDEX idx_devices_user_id ON devices(user_id);
CREATE INDEX idx_pairings_device_a ON pairings(device_a_id);
CREATE INDEX idx_pairings_device_b ON pairings(device_b_id);
CREATE INDEX idx_sessions_device_id ON sessions(device_id);
CREATE INDEX idx_sessions_user_id ON sessions(user_id);
CREATE INDEX idx_email_codes_email ON email_verification_codes(email);
