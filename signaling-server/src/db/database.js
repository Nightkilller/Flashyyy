'use strict';

/**
 * Pure JavaScript in-memory database mock that replicates the API of `better-sqlite3`.
 *
 * This avoids compiling native C++ code during `npm install`, bypassing compatibility issues
 * with newer Node.js versions (like Node 26) while keeping the prototype server fully functional.
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
    // No-op for schema initialization
  }

  prepare(sql) {
    const trimmed = sql.trim().replace(/\s+/g, ' ');

    // 1. SELECT id FROM devices WHERE id = ?
    if (trimmed.startsWith('SELECT id FROM devices WHERE id =')) {
      return {
        get: (id) => {
          return this.tables.devices.find(d => d.id === id);
        }
      };
    }

    // 2. UPDATE devices SET device_name = ?, last_seen_at = ? WHERE id = ?
    if (trimmed.startsWith('UPDATE devices SET device_name =') && trimmed.includes('last_seen_at =')) {
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

    // 3. UPDATE devices SET last_seen_at = ? WHERE id = ?
    if (trimmed.startsWith('UPDATE devices SET last_seen_at =')) {
      return {
        run: (lastSeenAt, id) => {
          const device = this.tables.devices.find(d => d.id === id);
          if (device) {
            device.last_seen_at = lastSeenAt;
          }
        }
      };
    }

    // 4. INSERT INTO devices (id, public_key, device_name, device_type, last_seen_at) VALUES (?, ?, ?, ?, ?)
    if (trimmed.startsWith('INSERT INTO devices')) {
      return {
        run: (id, publicKey, deviceName, deviceType, lastSeenAt) => {
          this.tables.devices.push({
            id,
            public_key: publicKey,
            device_name: deviceName,
            device_type: deviceType,
            last_seen_at: lastSeenAt
          });
        }
      };
    }

    // 5. INSERT INTO pairing_tokens (token, device_id, expires_at, used) VALUES (?, ?, ?, 0)
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

    // 6. SELECT * FROM pairing_tokens WHERE token = ?
    if (trimmed.startsWith('SELECT * FROM pairing_tokens WHERE token =')) {
      return {
        get: (token) => {
          return this.tables.pairing_tokens.find(t => t.token === token);
        }
      };
    }

    // 7. UPDATE pairing_tokens SET used = 1 WHERE token = ?
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

    // 8. INSERT INTO pairings (id, device_a_id, device_b_id) VALUES (?, ?, ?)
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

    // Fallback stub statement
    return {
      run: () => {},
      get: () => {},
      all: () => []
    };
  }
}

module.exports = new DatabaseMock();
