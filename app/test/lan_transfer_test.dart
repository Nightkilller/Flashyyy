import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flashy/core/identity/secure_storage.dart';
import 'package:flashy/core/identity/keypair_manager.dart';
import 'package:flashy/core/transport/lan_connection_manager.dart';
import 'package:flashy/core/transfer/resume_state_store.dart';
import 'package:flashy/core/transfer/transfer_manager.dart';
import 'package:flashy/core/transport/tls_connection.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late Directory sendDir;
  late Directory receiveDir;
  late File srcFile;
  late ResumeStateStore dbA;
  late ResumeStateStore dbB;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flashy_lan_test');
    sendDir = Directory('${tempDir.path}/send')..createSync();
    receiveDir = Directory('${tempDir.path}/receive')..createSync();

    // Create source test file with random binary data (1.5 MB)
    srcFile = File('${sendDir.path}/src.bin');
    final random = Random(12345);
    final randBytes = Uint8List(1500 * 1024);
    for (var i = 0; i < randBytes.length; i++) {
      randBytes[i] = random.nextInt(256);
    }
    await srcFile.writeAsBytes(randBytes);

    dbA = ResumeStateStore(dbPath: '${tempDir.path}/dbA.db');
    dbB = ResumeStateStore(dbPath: '${tempDir.path}/dbB.db');
    await dbA.init();
    await dbB.init();
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await tempDir.delete(recursive: true);
  });

  group('LAN Direct Secure Transfer Integration Tests', () {
    test('Handshake and transfer 1.5MB file over direct TLS connection', () async {
      // 1. Setup Identities
      final storageA = InMemorySecureStorage();
      final identityA = await KeypairManager.init(storageA, customDeviceName: 'Sender Device');

      final storageB = InMemorySecureStorage();
      final identityB = await KeypairManager.init(storageB, customDeviceName: 'Receiver Device');

      // Trusted Public Key lookups (cross-linked)
      final trustedKeys = {
        identityA.identity.deviceId: identityA.publicKeyHex,
        identityB.identity.deviceId: identityB.publicKeyHex,
      };

      Future<String?> getPublicKey(String id) async {
        return trustedKeys[id];
      }

      // 2. Setup LAN Managers
      final managerA = LanConnectionManager(
        identityManager: identityA,
        getTrustedPublicKey: getPublicKey,
      );

      final managerB = LanConnectionManager(
        identityManager: identityB,
        getTrustedPublicKey: getPublicKey,
      );

      // Start server on B
      final server = await managerB.startServer();
      
      // Accept incoming on B concurrently
      final serverConnCompleter = Completer<TlsConnection>();
      late StreamSubscription<SecureSocket> serverSub;
      
      serverSub = server.listen((socket) async {
        try {
          final conn = await managerB.handleIncomingConnection(socket);
          serverConnCompleter.complete(conn);
        } catch (e) {
          serverConnCompleter.completeError(e);
        }
      });

      // 3. Connect A (client) to B (server)
      final connA = await managerA.connectToPeer(
        ipAddress: '127.0.0.1',
        port: server.port,
        peerDeviceId: identityB.identity.deviceId,
      );

      expect(connA.remotePort, server.port);

      final connB = await serverConnCompleter.future.timeout(const Duration(seconds: 5));

      // 4. Run sender and receiver concurrently using TransferManager
      final senderManager = TransferManager(resumeStore: dbA);
      final receiverManager = TransferManager(resumeStore: dbB);

      final results = await Future.wait([
        senderManager.sendFile(connA, srcFile.path),
        receiverManager.receiveFiles(connB, receiveDir.path),
      ]);

      expect(results[0].success, isTrue, reason: 'Sender failed: ${results[0].errorMessage}');
      expect(results[1].success, isTrue, reason: 'Receiver failed: ${results[1].errorMessage}');

      // 5. Verify file integrity
      final destFile = File('${receiveDir.path}/src.bin');
      expect(destFile.existsSync(), isTrue);
      
      final destBytes = await destFile.readAsBytes();
      final srcBytes = await srcFile.readAsBytes();
      expect(destBytes.length, srcBytes.length);
      expect(destBytes, srcBytes);

      // Cleanup
      await serverSub.cancel();
      await server.close();
      await connA.close();
      await connB.close();
    });
  });
}
