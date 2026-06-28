import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

import 'package:flashy/core/identity/secure_storage.dart';
import 'package:flashy/core/identity/keypair_manager.dart';
import 'package:flashy/core/transport/lan_connection_manager.dart';
import 'package:flashy/core/transfer/file_chunker.dart';
import 'package:flashy/core/transfer/resume_state_store.dart';
import 'package:flashy/core/transfer/transfer_manager.dart';

void main() {
  late Directory tempDir;
  late File srcFile;
  late File destFile;
  late ResumeStateStore dbA;
  late ResumeStateStore dbB;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flashy_lan_test');
    
    // Create source test file with random binary data (1.5 MB)
    srcFile = File('${tempDir.path}/src.bin');
    final randBytes = Uint8List(1500 * 1024);
    for (var i = 0; i < randBytes.length; i++) {
      randBytes[i] = i % 256;
    }
    await srcFile.writeAsBytes(randBytes);

    destFile = File('${tempDir.path}/dest.bin');

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
      
      // Accept incoming on B
      final serverConnectionCompleter = Completer<LanConnectionManager>();
      late StreamSubscription<SecureSocket> serverSub;
      
      serverSub = server.listen((socket) async {
        try {
          final conn = await managerB.handleIncomingConnection(socket);
          // Start receiver transfer
          final receiverManager = TransferManager(conn, dbB);
          
          receiverManager.receiveProgress.listen((manifest) async {
            if (manifest.chunksReceived == manifest.totalChunks) {
              // Assemble file
              final writer = FileChunker(manifest, destFile.path);
              await writer.assembleFile();
            }
          });
        } catch (e) {
          fail('Server failed to authenticate client: $e');
        }
      });

      // 3. Connect A (client) to B (server)
      final connA = await managerA.connectToPeer(
        ipAddress: '127.0.0.1',
        port: server.port,
        peerDeviceId: identityB.identity.deviceId,
      );

      expect(connA.remotePort, server.port);

      // 4. Setup Sender Chunker
      final senderChunker = FileChunker.forSending(srcFile.path);
      final manifest = await senderChunker.manifest;
      
      final senderManager = TransferManager(connA, dbA);
      
      // Complete transfer
      final transferCompleter = Completer<void>();
      senderManager.sendProgress.listen((manifest) {
        if (manifest.chunksSent == manifest.totalChunks) {
          transferCompleter.complete();
        }
      });

      await senderManager.sendManifest(manifest);
      await senderManager.sendAllChunks(senderChunker);

      await transferCompleter.future.timeout(const Duration(seconds: 10));

      // Wait a moment for B to assemble
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // 5. Verify file integrity
      expect(destFile.existsSync(), isTrue);
      final destBytes = await destFile.readAsBytes();
      final srcBytes = await srcFile.readAsBytes();
      expect(destBytes.length, srcBytes.length);
      expect(destBytes, srcBytes);

      // Cleanup
      await serverSub.cancel();
      await server.close();
      await connA.close();
    });
  });
}
