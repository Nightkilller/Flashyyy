# Flashy 🚀
A secure, cross-platform peer-to-peer (P2P) file transfer application built with Flutter, Node.js, and WebRTC.

## Core Features
- **True Peer-to-Peer**: Stream files directly between devices on different networks using WebRTC, bypassing cloud storage.
- **Fast LAN Transfer**: Detects when devices are on the same local network and automatically uses a direct local TCP/TLS path.
- **Zero Configuration QR Pairing**: Scan a QR code once to permanently link devices together.
- **Bilingual Interface**: Beautiful, native-feeling UI supporting Hindi and English.
- **Resumable Transfers**: Interrupted transfers automatically resume from the last acknowledged chunk.

## Repository Structure
- `/app` — Flutter client targeting Android, iOS, macOS, Windows, and Linux.
- `/signaling-server` — Node.js WebSocket signaling server for device pairing, presence, and session management.
- `/turn-server` — coturn configuration for fallback TURN relay servers.
- `/docs` — System Architecture and Security specifications.
