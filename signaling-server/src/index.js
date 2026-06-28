'use strict';

require('dotenv').config();
const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const db = require('./db/database');
const presenceManager = require('./presence/presenceManager');
const pairingHandler = require('./pairing/pairingHandler');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 8080;

// HTTP Endpoint for pairing token generation
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

const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
  console.log('New connection established');

  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);
      const { action, payload } = data;
      if (!action || !payload) return;

      switch (action) {
        case 'register':
          const { deviceId, deviceName, deviceType, publicKey } = payload;
          if (deviceId && publicKey) {
            // Register device in sqlite DB
            const existing = db.prepare('SELECT id FROM devices WHERE id = ?').get(deviceId);
            if (!existing) {
              db.prepare(`
                INSERT INTO devices (id, public_key, device_name, device_type, last_seen_at)
                VALUES (?, ?, ?, ?, ?)
              `).run(deviceId, publicKey, deviceName || 'Device', deviceType || 'mobile', new Date().toISOString());
            } else {
              db.prepare(`
                UPDATE devices 
                SET device_name = ?, last_seen_at = ?
                WHERE id = ?
              `).run(deviceName || 'Device', new Date().toISOString(), deviceId);
            }
            presenceManager.register(deviceId, ws);
          }
          break;

        case 'heartbeat':
          // Refresh last_seen_at
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
      }
    } catch (e) {
      console.error('Error handling WebSocket message:', e.message);
    }
  });

  ws.on('close', () => {
    const deviceId = presenceManager.unregister(ws);
    if (deviceId) {
      console.log(`Connection closed for device: ${deviceId}`);
    } else {
      console.log('Connection closed for unregistered device');
    }
  });
});

server.listen(PORT, () => {
  console.log(`Flashy Signaling Server listening on port ${PORT}`);
});
