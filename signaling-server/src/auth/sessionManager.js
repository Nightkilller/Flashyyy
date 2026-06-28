'use strict';

const db = require('../db/database');
const crypto = require('crypto');

class SessionManager {
  /**
   * Generates a 30-day session token.
   */
  createSession(userId, deviceId) {
    const token = crypto.randomBytes(32).toString('hex');
    
    // Default 30 days session expiry
    const expiryDays = parseInt(process.env.SESSION_TOKEN_EXPIRY_DAYS || '30', 10);
    const expiresAt = new Date(Date.now() + expiryDays * 24 * 60 * 60 * 1000).toISOString();

    // Revoke any existing session for this device first (1 device = 1 active session)
    db.prepare('DELETE FROM sessions WHERE device_id = ?').run(deviceId);

    db.prepare(`
      INSERT INTO sessions (token, device_id, user_id, expires_at)
      VALUES (?, ?, ?, ?)
    `).run(token, deviceId, userId, expiresAt);

    return token;
  }

  /**
   * Validates a session token. Returns the session object if valid, null otherwise.
   */
  verifySession(token) {
    const session = db.prepare('SELECT * FROM sessions WHERE token = ?').get(token);
    if (!session) return null;

    const now = new Date().toISOString();
    if (session.expires_at < now) {
      // Session expired — delete it
      this.revokeSession(token);
      return null;
    }

    return session;
  }

  /**
   * Revokes a session token (logout).
   */
  revokeSession(token) {
    db.prepare('DELETE FROM sessions WHERE token = ?').run(token);
  }

  /**
   * Returns list of other devices linked to this user.
   */
  getUserLinkedDevices(userId, excludeDeviceId) {
    return db.prepare(`
      SELECT id, public_key, device_name, device_type, last_seen_at
      FROM devices
      WHERE user_id = ? AND id != ?
    `).all(userId, excludeDeviceId);
  }
}

module.exports = new SessionManager();
