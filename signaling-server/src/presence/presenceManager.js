'use strict';

class PresenceManager {
  constructor() {
    // Map of deviceId -> Set of WebSocket connections (supporting multiple tabs/connections per device)
    this.activeConnections = new Map();
    // Map of WebSocket connection -> deviceId
    this.connectionToDevice = new Map();
  }

  register(deviceId, ws) {
    this.connectionToDevice.set(ws, deviceId);
    
    if (!this.activeConnections.has(deviceId)) {
      this.activeConnections.set(deviceId, new Set());
    }
    this.activeConnections.get(deviceId).add(ws);
    
    console.log(`Device registered: ${deviceId} (Connections: ${this.activeConnections.get(deviceId).size})`);
  }

  unregister(ws) {
    const deviceId = this.connectionToDevice.get(ws);
    if (!deviceId) return null;

    this.connectionToDevice.delete(ws);
    const connections = this.activeConnections.get(deviceId);
    if (connections) {
      connections.delete(ws);
      if (connections.size === 0) {
        this.activeConnections.delete(deviceId);
        console.log(`Device went offline: ${deviceId}`);
        return deviceId; // Returns deviceId if it is fully offline
      }
    }
    return null;
  }

  isOnline(deviceId) {
    return this.activeConnections.has(deviceId);
  }

  sendToDevice(deviceId, action, payload) {
    const connections = this.activeConnections.get(deviceId);
    if (!connections || connections.size === 0) return false;

    const message = JSON.stringify({ action, payload });
    for (const ws of connections) {
      try {
        ws.send(message);
      } catch (e) {
        // Dead connection
      }
    }
    return true;
  }
}

module.exports = new PresenceManager();
