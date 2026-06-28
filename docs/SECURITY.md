# Flashy — Security Requirements

## Non-Negotiable Security Rules

These apply to ALL phases of development. Never bypass or weaken these.

### 1. Private Key Storage
- **Never** store the device private key outside secure platform storage
- Use `flutter_secure_storage` (backed by Keychain on iOS/macOS, Keystore on Android)
- Never store keys in plain files, SharedPreferences, or the app's regular SQLite DB

### 2. Pairing Token Security
- QR pairing tokens must be **single-use** and **time-limited** (~2 minutes)
- Server must invalidate a token immediately after one successful pairing
- Tokens must be cryptographically random (not sequential/guessable)

### 3. Transport Encryption
- All WebRTC data channels must use **DTLS** (default in WebRTC — verify it's not disabled)
- Never allow an unencrypted fallback for internet-facing connections
- The LAN-direct path must still use **TLS** even on local WiFi (public/guest WiFi is untrusted)

### 4. Relay Server Integrity
- The TURN relay must **never persist file bytes to disk** — relay only, in-memory buffering
- The signaling server only sees connection metadata — never file content, never full file names
- Use opaque transfer IDs in server logs instead of file names

### 5. Peer Authentication
- Verify peer identity using exchanged public keys at **every connection**, not just at initial pairing
- This prevents a compromised signaling server from redirecting a transfer to the wrong device
- Mutual TLS or signature-based authentication on each connection setup

### 6. Rate Limiting
- Rate-limit pairing and search endpoints to prevent token brute-forcing
- Rate-limit email verification: max 5 requests per 15 minutes per email address
- Rate-limit failed verification attempts to prevent code brute-forcing

### 7. Email Verification Security
- **Hash verification codes** before storing (same principle as passwords)
- Invalidate a code immediately after one successful use
- Codes expire after ~10 minutes

### 8. Session Management
- Session tokens must be **revocable** — signing out or removing a device must invalidate the token server-side immediately
- Don't just delete tokens client-side — the server must reject the token on next use
- Tokens should auto-expire and be refreshable

### 9. File Path Security (Phase 1 — Active Now)
- Transfer manifests use **relative paths only** — never absolute device paths
- The resume state SQLite database stores relative paths only
- This prevents leaking filesystem structure if the DB is somehow accessed
- Path traversal prevention: reject manifest entries containing `..` or absolute paths

### 10. Checksum Integrity (Phase 1 — Active Now)
- All file transfers verified with **SHA-256** checksums
- Checksums computed using streaming (chunked) hashing — never load full files into memory
- Receiver independently computes checksums and compares against manifest
- Transfer is marked as failed if any checksum doesn't match
