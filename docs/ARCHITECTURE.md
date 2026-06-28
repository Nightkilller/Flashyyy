# Flashy — System Architecture

## Overview

Flashy is a cross-platform peer-to-peer file transfer application that works across different networks (different WiFi, different cities, different countries) without uploading files to cloud storage.

## Architecture Diagram

```
┌─────────────────────────┐                    ┌─────────────────────────┐
│   Device A (Flutter)    │                    │   Device B (Flutter)    │
│  - File transfer engine │                    │  - File transfer engine │
│  - WebRTC data channel  │                    │  - WebRTC data channel  │
│  - mDNS LAN discovery   │                    │  - mDNS LAN discovery   │
│  - Local keypair + DB   │                    │  - Local keypair + DB   │
└───────────┬─────────────┘                    └────────────┬────────────┘
            │                                                │
            │     (1) LAN direct — same subnet, skip below   │
            │◄───────────────────────────────────────────────►│
            │                                                │
            │     (2) WebSocket — signaling only              │
            ▼                                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     SIGNALING SERVER (Node.js)                          │
│  - Device presence (online/offline) via WebSocket                       │
│  - Pairing token validation (QR pairing handshake)                      │
│  - Email login: code generation, verification, session tokens           │
│  - SDP offer/answer + ICE candidate relay (for WebRTC setup)            │
└─────────────────────────────────────────────────────────────────────────┘
            │
            │     (3) STUN — public, free
            ▼
   stun.l.google.com:19302
            │
            │     (4) Direct P2P via STUN-discovered addresses
            │◄──────────────────────────────────────────────────────────►│
            │
            │     (5) FALLBACK — TURN relay
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                  TURN RELAY SERVER (coturn, self-hosted)                 │
│  - Relays encrypted bytes when direct P2P fails                         │
│  - No disk writes, no payload logging, in-memory only                   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Summary

| Component | Responsibility | Tech | Where it runs |
|---|---|---|---|
| Client app | UI, file I/O, chunking/resume, WebRTC client, mDNS | Flutter + `flutter_webrtc` + `multicast_dns` | User's device |
| Signaling server | Presence, pairing, email login, SDP/ICE relay | Node.js + `ws` + SQLite | Oracle Cloud VM |
| Email service | Sends verification codes for email login | Resend (free tier) | External |
| STUN | NAT type/public address discovery | Google's free public STUN | External |
| TURN relay | Fallback relay when P2P fails | `coturn` (open source) | Oracle Cloud VM |
| Local storage | Device keypair, paired devices, transfer history | `flutter_secure_storage` + SQLite | User's device |

## Transfer Protocol (Phase 1)

### Message Framing

Every message over a connection is framed as:

```
┌──────────────────┬───────────┬────────────────────┐
│ 4 bytes          │ 1 byte    │ N bytes            │
│ Payload length   │ Type tag  │ Payload            │
│ (big-endian)     │           │                    │
└──────────────────┴───────────┴────────────────────┘
```

### Message Types

| Tag | Name | Direction | Payload |
|-----|------|-----------|---------|
| `0x01` | Manifest | Sender → Receiver | JSON: `TransferManifest` |
| `0x02` | FileChunk | Sender → Receiver | Binary: `[fileIndex][chunkIndex][offset][length][data]` |
| `0x03` | ACK | Receiver → Sender | JSON: `{fileIndex, chunkIndex, offset, length}` |
| `0x04` | TransferComplete | Sender → Receiver | Empty |
| `0x05` | VerifyOK | Receiver → Sender | Empty |
| `0x06` | VerifyFailed | Receiver → Sender | JSON: `{failedFiles: [...]}` |
| `0x07` | TransferRequest | Sender → Receiver | JSON: transfer metadata (Phase 2+) |

### FileChunk Binary Format

```
┌──────────────┬──────────────┬──────────────┬──────────────┬─────────┐
│ 4 bytes      │ 4 bytes      │ 8 bytes      │ 4 bytes      │ N bytes │
│ fileIndex    │ chunkIndex   │ offset       │ data length  │ data    │
│ (big-endian) │ (big-endian) │ (big-endian) │ (big-endian) │         │
└──────────────┴──────────────┴──────────────┴──────────────┴─────────┘
```

### Transfer Flow

1. **Sender** generates a `TransferManifest` (file list + SHA-256 checksums)
2. **Sender** sends manifest as first message
3. **Sender** streams `FileChunk` messages, one per chunk (default 512KB)
4. **Receiver** writes each chunk to disk and sends an `ACK`
5. **Sender** waits for ACK before sending next chunk (flow control)
6. After all files: **Sender** sends `TransferComplete`
7. **Receiver** verifies SHA-256 checksums for all files
8. **Receiver** sends `VerifyOK` or `VerifyFailed`

### Resume Logic

- Both sides persist progress to SQLite (`ResumeStateStore`)
- On reconnect, sender checks last acknowledged offset per file
- Sender skips already-acknowledged chunks
- Receiver opens files in append mode at the correct offset

## Connection Abstraction

All transport layers implement the `Connection` interface:

```dart
abstract class Connection {
  Future<void> sendBytes(Uint8List data);
  Stream<Uint8List> get incomingBytes;
  Future<void> close();
  bool get isConnected;
}
```

**Implementations:**
- `LocalhostConnection` — TCP on 127.0.0.1 (Phase 1 testing)
- `LanDirectConnection` — TCP/TLS over local network (Phase 3)
- `WebRTCConnection` — WebRTC data channel (Phase 4)

## Build Phases

| Phase | What | Status |
|-------|------|--------|
| 1 | Local file transfer engine | ✅ Built |
| 2 | Device identity + QR pairing | Planned |
| 2B | Email login + device linking | Planned |
| 3 | LAN direct transfer | Planned |
| 4 | WebRTC cross-network P2P | Planned |
| 5 | TURN relay fallback | Planned |
| 6 | Polish, security hardening, packaging | Planned |
