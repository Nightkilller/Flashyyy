'use strict';

/**
 * Pure JavaScript in-memory database mock that replicates the API of `better-sqlite3`.
 * Handles all queries for Devices, Pairings, users, sessions, and email_verification_codes.
 */
class DatabaseMock {
  constructor() {
    this.tables = {
      devices: [],
      pairing_tokens: [],
      pairings: [],
      users: [],
      sessions: [],
      email_verification_codes: []
    };
  }

  exec(sql) {
    // No-op
  }

  prepare(sql) {
    const trimmed = sql.trim().replace(/\s+/g, ' ');

    // --- Users Table ---
    if (trimmed.startsWith('SELECT * FROM users WHERE email =')) {
      return {
        get: (email) => {
          return this.tables.users.find(u => u.email === email);
        }
      };
    }
    if (trimmed.startsWith('INSERT INTO users (id, email)')) {
      return {
        run: (id, email) => {
          this.tables.users.push({
            id,
            email,
            created_at: new Date().toISOString()
          });
        }
      };
    }

    // --- Devices Table ---
    if (trimmed.startsWith('SELECT id FROM devices WHERE id =')) {
      return {
        get: (id) => {
          return this.tables.devices.find(d => d.id === id);
        }
      };
    }
    if (trimmed.startsWith('UPDATE devices SET user_id = ? WHERE id = ?')) {
      return {
        run: (userId, id) => {
          const device = this.tables.devices.find(d => d.id === id);
          if (device) {
            device.user_id = userId;
          }
        }
      };
    }
    if (trimmed.startsWith('UPDATE devices SET user_id = NULL WHERE id = ?')) {
      return {
        run: (id) => {
          const device = this.tables.devices.find(d => d.id === id);
          if (device) {
            device.user_id = null;
          }
        }
      };
    }
    if (trimmed.startsWith('SELECT * FROM devices WHERE user_id =') && trimmed.includes('AND id != ?')) {
      return {
        all: (userId, excludeDeviceId) => {
          return this.tables.devices.filter(d => d.user_id === userId && d.id !== excludeDeviceId);
        }
      };
    }
    if (trimmed.startsWith('UPDATE devices SET device_name = ?, last_seen_at = ? WHERE id = ?')) {
      return {
        run: (deviceName, lastSeenAt, id) => {
          const device = this.tables.devices.find(d => d.id === id);
          if (device) {
            device.device_name = deviceName;
            device.last_seen_at = lastSeenAt;
          }
        }
      };
    }
    if (trimmed.startsWith('UPDATE devices SET last_seen_at = ? WHERE id = ?')) {
      return {
        run: (lastSeenAt, id) => {
          const device = this.tables.devices.find(d => d.id === id);
          if (device) {
            device.last_seen_at = lastSeenAt;
          }
        }
      };
    }
    if (trimmed.startsWith('INSERT INTO devices')) {
      return {
        run: (id, publicKey, deviceName, deviceType, lastSeenAt) => {
          this.tables.devices.push({
            id,
            user_id: null,
            public_key: publicKey,
            device_name: deviceName,
            device_type: deviceType,
            last_seen_at: lastSeenAt
          });
        }
      };
    }

    // --- Pairing Tokens ---
    if (trimmed.startsWith('INSERT INTO pairing_tokens')) {
      return {
        run: (token, deviceId, expiresAt) => {
          this.tables.pairing_tokens.push({
            token,
            device_id: deviceId,
            expires_at: expiresAt,
            used: 0
          });
        }
      };
    }
    if (trimmed.startsWith('SELECT * FROM pairing_tokens WHERE token =')) {
      return {
        get: (token) => {
          return this.tables.pairing_tokens.find(t => t.token === token);
        }
      };
    }
    if (trimmed.startsWith('UPDATE pairing_tokens SET used = 1')) {
      return {
        run: (token) => {
          const t = this.tables.pairing_tokens.find(t => t.token === token);
          if (t) {
            t.used = 1;
          }
        }
      };
    }

    // --- Pairings ---
    if (trimmed.startsWith('INSERT INTO pairings')) {
      return {
        run: (id, deviceAId, deviceBId) => {
          this.tables.pairings.push({
            id,
            device_a_id: deviceAId,
            device_b_id: deviceBId
          });
        }
      };
    }

    // --- Email Verification Codes ---
    if (trimmed.startsWith('INSERT INTO email_verification_codes')) {
      return {
        run: (email, code, expiresAt) => {
          this.tables.email_verification_codes.push({
            email,
            code,
            expires_at: expiresAt,
            used: 0
          });
        }
      };
    }
    if (trimmed.startsWith('SELECT * FROM email_verification_codes WHERE email =') && trimmed.includes('AND code =')) {
      return {
        get: (email, code) => {
          return this.tables.email_verification_codes.find(c => c.email === email && c.code === code);
        }
      };
    }
    if (trimmed.startsWith('UPDATE email_verification_codes SET used = 1 WHERE email =') && trimmed.includes('AND code =')) {
      return {
        run: (email, code) => {
          const c = this.tables.email_verification_codes.find(c => c.email === email && c.code === code);
          if (c) {
            c.used = 1;
          }
        }
      };
    }

    // --- Sessions ---
    if (trimmed.startsWith('INSERT INTO sessions')) {
      return {
        run: (token, deviceId, userId, expiresAt) => {
          this.tables.sessions.push({
            token,
            device_id: deviceId,
            user_id: userId,
            expires_at: expiresAt,
            created_at: new Date().toISOString()
          });
        }
      };
    }
    if (trimmed.startsWith('SELECT * FROM sessions WHERE token =')) {
      return {
        get: (token) => {
          return this.tables.sessions.find(s => s.token === token);
        }
      };
    }
    if (trimmed.startsWith('DELETE FROM sessions WHERE token =')) {
      return {
        run: (token) => {
          this.tables.sessions = this.tables.sessions.filter(s => s.token !== token);
        }
      };
    }
    if (trimmed.startsWith('DELETE FROM sessions WHERE device_id =')) {
      return {
        run: (deviceId) => {
          this.tables.sessions = this.tables.sessions.filter(s => s.device_id !== deviceId);
        }
      };
    }

    // Fallback stub statement
    return {
      run: () => {},
      get: () => {},
      all: () => []
    };
  }
}

module.exports = new DatabaseMock();
