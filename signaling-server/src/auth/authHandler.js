'use strict';

const db = require('../db/database');
const crypto = require('crypto');
const emailSender = require('./emailSender');
const sessionManager = require('./sessionManager');

// Keep in-memory timestamps of code requests to rate limit: email -> [timestamps]
const requestRateLimits = new Map();

class AuthHandler {
  /**
   * Hashes a 6-digit code using SHA-256 (security requirement 9).
   */
  hashValue(val) {
    return crypto.createHash('sha256').update(val).digest('hex');
  }

  /**
   * Checks the rate limit for requesting verification codes.
   * Returns true if allowed, false if blocked (security requirement 8).
   */
  _checkRateLimit(email) {
    const now = Date.now();
    const windowMs = (process.env.EMAIL_CODE_RATE_LIMIT_WINDOW_SECONDS || 900) * 1000; // 15 mins
    const maxRequests = parseInt(process.env.EMAIL_CODE_RATE_LIMIT_MAX || '5', 10);

    if (!requestRateLimits.has(email)) {
      requestRateLimits.set(email, []);
    }

    const timestamps = requestRateLimits.get(email);
    // Filter timestamps within the current window
    const activeTimestamps = timestamps.filter(t => now - t < windowMs);
    requestRateLimits.set(email, activeTimestamps);

    if (activeTimestamps.length >= maxRequests) {
      return false;
    }

    activeTimestamps.push(now);
    return true;
  }

  /**
   * API request code generation.
   */
  async requestCode(req, finalRes) {
    const { email } = req.body;
    if (!email || !email.includes('@')) {
      return finalRes.status(400).json({ error: 'Valid email address required' });
    }

    // 1. Enforce rate limiting
    if (!this._checkRateLimit(email)) {
      return finalRes.status(429).json({
        error: 'Too many requests. Please try again after 15 minutes.'
      });
    }

    // 2. Generate 6-digit code
    const code = Math.floor(100000 + Math.random() * 900000).toString();
    const hashedCode = this.hashValue(code);

    // Default 10 minutes expiry
    const expirySec = parseInt(process.env.EMAIL_CODE_EXPIRY_SECONDS || '600', 10);
    const expiresAt = new Date(Date.now() + expirySec * 1000).toISOString();

    // 3. Store hashed code in DB
    db.prepare(`
      INSERT OR REPLACE INTO email_verification_codes (email, code, expires_at, used)
      VALUES (?, ?, ?, 0)
    `).run(email, hashedCode, expiresAt);

    // 4. Send email (async)
    try {
      await emailSender.sendVerificationEmail(email, code);
      finalRes.status(200).json({ message: 'Verification code sent' });
    } catch (e) {
      finalRes.status(500).json({ error: 'Failed to send email' });
    }
  }

  /**
   * API code verification.
   */
  async verifyCode(req, finalRes) {
    const { email, code, deviceId, deviceName, publicKey } = req.body;
    if (!email || !code || !deviceId) {
      return finalRes.status(400).json({ error: 'Missing required parameters' });
    }

    const hashedCode = this.hashValue(code);

    // 1. Look up code in DB
    const codeRow = db.prepare(`
      SELECT * FROM email_verification_codes 
      WHERE email = ? AND code = ?
    `).get(email, hashedCode);

    if (!codeRow) {
      return finalRes.status(400).json({ error: 'Invalid verification code' });
    }

    if (codeRow.used === 1) {
      return finalRes.status(400).json({ error: 'Verification code already used' });
    }

    const now = new Date().toISOString();
    if (codeRow.expires_at < now) {
      return finalRes.status(400).json({ error: 'Verification code expired' });
    }

    // 2. Find or create user row
    let user = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
    if (!user) {
      const userId = crypto.randomUUID();
      db.prepare('INSERT INTO users (id, email) VALUES (?, ?)').run(userId, email);
      user = { id: userId, email };
    }

    // 3. Register device if not present, and update user_id association
    const existingDevice = db.prepare('SELECT id FROM devices WHERE id = ?').get(deviceId);
    if (!existingDevice) {
      db.prepare(`
        INSERT INTO devices (id, public_key, device_name, device_type, user_id, last_seen_at)
        VALUES (?, ?, ?, 'mobile', ?, ?)
      `).run(deviceId, publicKey || 'unknown', deviceName || 'Device', user.id, new Date().toISOString());
    } else {
      db.prepare(`
        UPDATE devices 
        SET user_id = ?, last_seen_at = ?
        WHERE id = ?
      `).run(user.id, new Date().toISOString(), deviceId);
    }

    // 4. Mark code as used
    db.prepare(`
      UPDATE email_verification_codes 
      SET used = 1 
      WHERE email = ? AND code = ?
    `).run(email, hashedCode);

    // 5. Create session token
    const token = sessionManager.createSession(user.id, deviceId);

    finalRes.status(200).json({
      userId: user.id,
      email: user.email,
      sessionToken: token
    });
  }

  /**
   * API logout.
   */
  async logout(req, finalRes) {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return finalRes.status(401).json({ error: 'Unauthorized' });
    }

    const token = authHeader.substring(7);
    sessionManager.revokeSession(token);

    finalRes.status(200).json({ message: 'Logged out successfully' });
  }
}

module.exports = new AuthHandler();
