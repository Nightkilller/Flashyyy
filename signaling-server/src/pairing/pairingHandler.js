'use strict';

const db = require('../db/database');
const presenceManager = require('../presence/presenceManager');
const crypto = require('crypto');

class PairingHandler {
  /**
   * Generates a 2-minute pairing token for Device A.
   */
  generateToken(deviceId) {
    const token = crypto.randomBytes(16).toString('hex');
    const expiresAt = new Date(Date.now() + 120000).toISOString(); // 2 minutes

    // Store in sqlite DB
    const stmt = db.prepare(`
      INSERT INTO pairing_tokens (token, device_id, expires_at, used)
      VALUES (?, ?, ?, 0)
    `);
    stmt.run(token, deviceId);

    return token;
  }

  /**
   * Device B sends a pairing request using A's token.
   */
  handlePairingRequest(ws, payload) {
    const { token, deviceId, deviceName, publicKey, signature } = payload;

    // 1. Look up token details in DB
    const tokenRow = db.prepare('SELECT * FROM pairing_tokens WHERE token = ?').get(token);
    if (!tokenRow) {
      this._sendError(ws, token, 'Invalid pairing token');
      return;
    }

    if (tokenRow.used === 1) {
      this._sendError(ws, token, 'Token already used');
      return;
    }

    const now = new Date().toISOString();
    if (tokenRow.expires_at < now) {
      this._sendError(ws, token, 'Token expired');
      return;
    }

    const hostDeviceId = tokenRow.device_id;

    // 2. Ensure Host (Device A) is online
    if (!presenceManager.isOnline(hostDeviceId)) {
      this._sendError(ws, token, 'Host device is offline');
      return;
    }

    // 3. Register Device B in DB if not present
    this._registerDevice(deviceId, deviceName, publicKey);

    // 4. Forward request to Device A over WebSocket
    presenceManager.sendToDevice(hostDeviceId, 'pairingRequest', {
      token,
      deviceId,
      deviceName,
      publicKey,
      signature,
    });
  }

  /**
   * Device A responds to Device B's request.
   */
  handlePairingResponse(ws, payload) {
    const { token, success, deviceId, deviceName, publicKey, signature, error } = payload;

    // Look up token to find Device B's connection
    const tokenRow = db.prepare('SELECT * FROM pairing_tokens WHERE token = ?').get(token);
    if (!tokenRow) return;

    const hostDeviceId = tokenRow.device_id;

    if (!success) {
      // Forward failure to Device B
      // Wait, how do we know Device B's device ID? The token doesn't store B's ID,
      // but in handlePairingRequest we forwarded A's token. B is waiting on its own pairing completion.
      // Wait, let's keep track of B's device ID during the handshake. Or we can store
      // B's ID in a temporary map on the server, or store it in DB.
      // Better: we can temporarily save the transaction in memory or DB.
      // Let's store B's device ID in the pairing_tokens table by adding a column?
      // No, we can just store the active pairing request in a map: token -> deviceIdB.
      const deviceIdB = this._activePairingRequests.get(token);
      if (deviceIdB) {
        presenceManager.sendToDevice(deviceIdB, 'pairingResponse', {
          token,
          success: false,
          error: error || 'Host rejected pairing',
        });
        this._activePairingRequests.delete(token);
      }
      return;
    }

    // Success response: A accepted
    const deviceIdB = this._activePairingRequests.get(token);
    if (!deviceIdB) return;

    // Register Device A in DB if not present
    this._registerDevice(deviceId, deviceName, publicKey);

    // Create pairing record
    const pairingId = crypto.randomUUID();
    const insertPairing = db.prepare(`
      INSERT INTO pairings (id, device_a_id, device_b_id)
      VALUES (?, ?, ?)
    `);
    
    try {
      insertPairing.run(pairingId, hostDeviceId, deviceIdB);
    } catch (_) {
      // Already paired, ignore
    }

    // Mark token as used in DB
    db.prepare('UPDATE pairing_tokens SET used = 1 WHERE token = ?').run(token);

    // Forward response to B
    presenceManager.sendToDevice(deviceIdB, 'pairingResponse', {
      token,
      success: true,
      deviceId,
      deviceName,
      publicKey,
      signature,
    });

    this._activePairingRequests.delete(token);
  }

  _registerDevice(deviceId, deviceName, publicKey) {
    const checkStmt = db.prepare('SELECT id FROM devices WHERE id = ?');
    const existing = checkStmt.get(deviceId);
    if (!existing) {
      db.prepare(`
        INSERT INTO devices (id, public_key, device_name, device_type)
        VALUES (?, ?, ?, 'mobile')
      `).run(deviceId, publicKey, deviceName);
    }
  }

  _sendError(ws, token, message) {
    ws.send(JSON.stringify({
      action: 'pairingResponse',
      payload: {
        token,
        success: false,
        error: message,
      },
    }));
  }

  trackRequest(token, deviceIdB) {
    this._activePairingRequests.set(token, deviceIdB);
  }
}

// Global active pairing requests map
PairingHandler.prototype._activePairingRequests = new Map();

module.exports = new PairingHandler();
