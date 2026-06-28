'use strict';

require('dotenv').config();
const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const db = require('./db/database');
const presenceManager = require('./presence/presenceManager');
const pairingHandler = require('./pairing/pairingHandler');
const authHandler = require('./auth/authHandler');
const sessionManager = require('./auth/sessionManager');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;

// HTTP Endpoints for pairing token generation
app.post('/api/pairing/token', (req, finalRes) => {
  const { deviceId } = req.body;
  if (!deviceId) {
    return finalRes.status(400).json({ error: 'Missing deviceId' });
  }
  try {
    const token = pairingHandler.generateToken(deviceId);
    finalRes.status(200).json({ token });
  } catch (e) {
    finalRes.status(500).json({ error: e.message });
  }
});

// HTTP Endpoints for Email Authentication
app.post('/api/auth/request-code', (req, finalRes) => {
  authHandler.requestCode(req, finalRes);
});

app.post('/api/auth/verify-code', (req, finalRes) => {
  authHandler.verifyCode(req, finalRes);
});

app.post('/api/auth/logout', (req, finalRes) => {
  authHandler.logout(req, finalRes);
});

const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
  console.log('New connection established');
  let currentDeviceId = null;
  let currentUserId = null;

  ws.on('message', async (message) => {
    try {
      const data = JSON.parse(message);
      const { action, payload } = data;
      if (!action || !payload) return;

      switch (action) {
        case 'register': {
          const { deviceId, deviceName, deviceType, publicKey, sessionToken } = payload;
          if (!deviceId || !publicKey) return;

          currentDeviceId = deviceId;
          
          let userId = null;
          // Verify session if token is provided
          if (sessionToken) {
            const session = sessionManager.verifySession(sessionToken);
            if (session) {
              userId = session.user_id;
              currentUserId = userId;
            }
          }

          // Register or update device in sqlite DB
          const existing = db.prepare('SELECT id FROM devices WHERE id = ?').get(deviceId);
          if (!existing) {
            db.prepare(`
              INSERT INTO devices (id, public_key, device_name, device_type, user_id, last_seen_at)
              VALUES (?, ?, ?, ?, ?, ?)
            `).run(deviceId, publicKey, deviceName || 'Device', deviceType || 'mobile', userId, new Date().toISOString());
          } else {
            // Update last seen and session association
            db.prepare(`
              UPDATE devices 
              SET device_name = ?, user_id = ?, last_seen_at = ?
              WHERE id = ?
            `).run(deviceName || 'Device', userId || existing.user_id, new Date().toISOString(), deviceId);
          }
          
          presenceManager.register(deviceId, ws);

          // Broadcast presence update (online) to all linked devices if logged in
          if (userId) {
            _broadcastPresence(userId, deviceId, true);
          }
          break;
        }

        case 'heartbeat':
          if (payload.deviceId) {
            db.prepare('UPDATE devices SET last_seen_at = ? WHERE id = ?')
              .run(new Date().toISOString(), payload.deviceId);
          }
          break;

        case 'pairingRequest':
          pairingHandler.trackRequest(payload.token, payload.deviceId);
          pairingHandler.handlePairingRequest(ws, payload);
          break;

        case 'pairingResponse':
          pairingHandler.handlePairingResponse(ws, payload);
          break;

        case 'getLinkedDevices': {
          if (!currentUserId || !currentDeviceId) {
            ws.send(JSON.stringify({
              action: 'linkedDevices',
              payload: { devices: [] }
            }));
            return;
          }

          // Get other devices linked to this user's email
          const devices = sessionManager.getUserLinkedDevices(currentUserId, currentDeviceId);
          // Attach online status
          const devicesWithStatus = devices.map(d => ({
            ...d,
            isOnline: presenceManager.isOnline(d.id)
          }));

          ws.send(JSON.stringify({
            action: 'linkedDevices',
            payload: { devices: devicesWithStatus }
          }));
          break;
        }
      }
    } catch (e) {
      console.error('Error handling WebSocket message:', e.message);
    }
  });

  ws.on('close', () => {
    if (currentDeviceId) {
      presenceManager.unregister(ws);
      console.log(`Connection closed for device: ${currentDeviceId}`);

      if (currentUserId) {
        _broadcastPresence(currentUserId, currentDeviceId, false);
      }
    }
  });

  // Helper to notify other linked devices of presence status
  function _broadcastPresence(userId, deviceId, isOnline) {
    const siblingDevices = sessionManager.getUserLinkedDevices(userId, deviceId);
    for (const sibling of siblingDevices) {
      presenceManager.sendToDevice(sibling.id, 'presenceUpdate', {
        deviceId,
        isOnline
      });
    }
  }
});

server.listen(PORT, () => {
  console.log(`Flashy Signaling Server listening on port ${PORT}`);
});
