import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../identity/keypair_manager.dart';
import 'tls_connection.dart';
import 'tls_credentials.dart';

/// Manages secure LAN TLS listener socket server and client connections,
/// executing mutual cryptographic Ed25519 challenge-response handshakes.
class LanConnectionManager {
  final KeypairManager identityManager;
  final Future<String?> Function(String deviceId) getTrustedPublicKey;

  LanConnectionManager({
    required this.identityManager,
    required this.getTrustedPublicKey,
  });

  /// Starts a secure server listening for incoming LAN connections.
  Future<SecureServerSocket> startServer({int port = 0}) async {
    final context = SecurityContext(withTrustedRoots: false);
    context.useCertificateChainBytes(utf8.encode(TlsCredentials.certificatePem));
    context.usePrivateKeyBytes(utf8.encode(TlsCredentials.privateKeyPem));

    return await SecureServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
      context,
    );
  }

  /// Handles authentication for an incoming connection on the server side.
  /// Returns an authenticated [TlsConnection] or throws an [AuthenticationException].
  Future<TlsConnection> handleIncomingConnection(SecureSocket socket) async {
    final conn = TlsConnection(socket);
    final lines = conn.incomingBytes.map(utf8.decode).transform(const LineSplitter());
    final iterator = StreamIterator(lines);
    try {
      final challengeBytes = _generateRandomBytes(32);
      final challengeHex = _toHex(challengeBytes);

      // 1. Send challenge to client
      await conn.sendBytes(utf8.encode(jsonEncode({'action': 'challenge', 'challenge': challengeHex}) + '\n'));

      // 2. Wait for client response
      if (!await iterator.moveNext()) {
        throw const HttpException('Client disconnected before sending challenge response');
      }

      final response = jsonDecode(iterator.current) as Map<String, dynamic>;
      if (response['action'] != 'response') {
        throw const HttpException('Invalid handshake sequence from client');
      }

      final clientDeviceId = response['deviceId'] as String;
      final clientSignatureHex = response['signature'] as String;
      final clientChallengeHex = response['clientChallenge'] as String;

      // 3. Verify client signature
      final clientPublicKeyHex = await getTrustedPublicKey(clientDeviceId);
      if (clientPublicKeyHex == null) {
        throw HttpException('Device $clientDeviceId is not a trusted contact');
      }

      final isClientValid = await KeypairManager.verify(
        challengeBytes,
        _fromHex(clientSignatureHex),
        _fromHex(clientPublicKeyHex),
      );

      if (!isClientValid) {
        throw const HttpException('Client signature verification failed');
      }

      // 4. Sign client's challenge and send back response
      final clientChallengeBytes = _fromHex(clientChallengeHex);
      final mySignatureHex = _toHex(await identityManager.sign(clientChallengeBytes));

      await conn.sendBytes(utf8.encode(jsonEncode({
        'action': 'authOk',
        'deviceId': identityManager.identity.deviceId,
        'signature': mySignatureHex,
      }) + '\n'));

      return conn;
    } catch (e) {
      conn.close();
      rethrow;
    } finally {
      await iterator.cancel();
    }
  }

  /// Establishes a secure connection to a peer device as a client.
  /// Returns an authenticated [TlsConnection] or throws an [AuthenticationException].
  Future<TlsConnection> connectToPeer({
    required String ipAddress,
    required int port,
    required String peerDeviceId,
  }) async {
    final socket = await SecureSocket.connect(
      ipAddress,
      port,
      onBadCertificate: (X509Certificate cert) {
        // Bypass CA validation since we use custom Ed25519 signature verification instead
        return true;
      },
      timeout: const Duration(seconds: 5),
    );

    final conn = TlsConnection(socket);
    final lines = conn.incomingBytes.map(utf8.decode).transform(const LineSplitter());
    final iterator = StreamIterator(lines);
    try {
      // 1. Await server's challenge
      if (!await iterator.moveNext()) {
        throw const HttpException('Server disconnected before sending challenge');
      }

      final hostChallengeData = jsonDecode(iterator.current) as Map<String, dynamic>;
      if (hostChallengeData['action'] != 'challenge') {
        throw const HttpException('Invalid handshake sequence from host');
      }

      final hostChallengeHex = hostChallengeData['challenge'] as String;
      final hostChallengeBytes = _fromHex(hostChallengeHex);

      // 2. Sign host's challenge and generate client challenge
      final mySignatureHex = _toHex(await identityManager.sign(hostChallengeBytes));
      final clientChallengeBytes = _generateRandomBytes(32);
      final clientChallengeHex = _toHex(clientChallengeBytes);

      // 3. Send response and own challenge
      await conn.sendBytes(utf8.encode(jsonEncode({
        'action': 'response',
        'deviceId': identityManager.identity.deviceId,
        'signature': mySignatureHex,
        'clientChallenge': clientChallengeHex,
      }) + '\n'));

      // 4. Await server verification response
      if (!await iterator.moveNext()) {
        throw const HttpException('Server disconnected before replying to challenge');
      }

      final hostResponse = jsonDecode(iterator.current) as Map<String, dynamic>;
      if (hostResponse['action'] != 'authOk') {
        throw const HttpException('Mutual authentication rejected by host');
      }

      final hostSignatureHex = hostResponse['signature'] as String;

      // 5. Verify server signature
      final hostPublicKeyHex = await getTrustedPublicKey(peerDeviceId);
      if (hostPublicKeyHex == null) {
        throw HttpException('Host $peerDeviceId is not a trusted contact');
      }

      final isHostValid = await KeypairManager.verify(
        clientChallengeBytes,
        _fromHex(hostSignatureHex),
        _fromHex(hostPublicKeyHex),
      );

      if (!isHostValid) {
        throw const HttpException('Server signature verification failed');
      }

      return conn;
    } catch (e) {
      conn.close();
      rethrow;
    } finally {
      await iterator.cancel();
    }
  }

  // --- Helpers ---

  Uint8List _generateRandomBytes(int length) {
    final rand = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => rand.nextInt(256)));
  }

  String _toHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Uint8List _fromHex(String hex) {
    final list = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      list.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(list);
  }
}
