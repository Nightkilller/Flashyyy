import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

import '../lib/core/identity/secure_storage.dart';
import '../lib/core/identity/keypair_manager.dart';
import '../lib/core/storage/local_database.dart';
import '../lib/core/transfer/resume_state_store.dart';
import '../lib/core/transfer/transfer_manager.dart';
import '../lib/core/transport/lan_connection_manager.dart';
import '../lib/core/transport/tls_connection.dart';

void main(List<String> arguments) async {
  if (arguments.isEmpty || (arguments[0] != 'send' && arguments[0] != 'receive')) {
    print('Flashy CLI Transfer Tool');
    print('-------------------------');
    print('Usage:');
    print('  dart run bin/flashy.dart receive');
    print('  dart run bin/flashy.dart send <receiver-ip> <file-path>');
    return;
  }

  final mode = arguments[0];

  // 1. Initialize databases & mock storage
  final storage = InMemorySecureStorage();
  final identity = await KeypairManager.init(storage);
  final contactsDb = LocalDatabase(dbPath: 'cli_contacts.db');
  await contactsDb.init();

  final resumeDb = ResumeStateStore(dbPath: 'cli_transfers.db');
  await resumeDb.init();

  // Helper: auto-pair so handshake verification succeeds
  // In production this is done via QR scan or Email login.
  // For the CLI tool, we auto-register the peer keys.
  final peerDummyId = 'peer-device-id';
  final peerDummyName = 'Peer Terminal';
  final peerDummyPubKey = identity.publicKeyHex; // trust self for easy testing
  await contactsDb.addContact(
    deviceId: peerDummyId,
    deviceName: peerDummyName,
    publicKey: peerDummyPubKey,
  );

  final connectionManager = LanConnectionManager(
    identityManager: identity,
    getTrustedPublicKey: (id) async {
      // Auto-trust peer-device-id
      return peerDummyPubKey;
    },
  );

  if (mode == 'receive') {
    print('Initializing receiver...');
    final secureServer = await connectionManager.startServer(port: 9999);
    print('=============================================');
    print('🟢 Flashy Receiver Listening on Port: 9999');
    print('   Target IP: 127.0.0.1 (Localhost)');
    print('=============================================');

    await for (final socket in secureServer) {
      print('Incoming connection from ${socket.remoteAddress.address}...');
      try {
        final conn = await connectionManager.handleIncomingConnection(socket);
        print('🔒 Mutual authentication successful!');

        final receiver = TransferManager(resumeStore: resumeDb);
        
        // Listen to progress updates
        receiver.receiveProgress.listen((manifest) {
          final progress = manifest.totalChunks > 0 
              ? (manifest.chunksReceived / manifest.totalChunks * 100) 
              : 0.0;
          stdout.write('\rReceiving chunks: ${manifest.chunksReceived}/${manifest.totalChunks} (${progress.toStringAsFixed(1)}%)');
        });

        // Save incoming files to a local download folder
        final downloadDir = Directory('downloads');
        if (!await downloadDir.exists()) {
          await downloadDir.create();
        }

        await receiver.receiveFiles(conn, downloadDir.path);
        print('\n🎉 File received successfully and saved to ${downloadDir.path}/');
        await conn.close();
        break; // Exit after single transfer
      } catch (e) {
        print('\n❌ Receiver error: $e');
        socket.close();
      }
    }
    await secureServer.close();
  } else if (mode == 'send') {
    if (arguments.length < 3) {
      print('Error: Missing arguments for send mode.');
      print('Usage: dart run bin/flashy.dart send <receiver-ip> <file-path>');
      return;
    }

    final ip = arguments[1];
    final filePath = arguments[2];
    final file = File(filePath);

    if (!await file.exists()) {
      print('Error: File "$filePath" does not exist.');
      return;
    }

    print('Connecting to receiver at $ip:9999...');
    TlsConnection? conn;
    try {
      conn = await connectionManager.connectToPeer(
        ipAddress: ip,
        port: 9999,
        peerDeviceId: peerDummyId,
      );
      print('🔒 Mutual authentication successful!');
    } catch (e) {
      print('❌ Connection/Authentication failed: $e');
      return;
    }

    final sender = TransferManager(resumeStore: resumeDb);
    
    // Listen to progress updates
    sender.sendProgress.listen((manifest) {
      final progress = manifest.totalChunks > 0 
          ? (manifest.chunksSent / manifest.totalChunks * 100) 
          : 0.0;
      stdout.write('\rSending chunks: ${manifest.chunksSent}/${manifest.totalChunks} (${progress.toStringAsFixed(1)}%)');
    });

    try {
      print('Streaming ${file.path} (${await file.length()} bytes)...');
      await sender.sendFile(conn, file.path);
      print('\n🎉 File sent successfully!');
    } catch (e) {
      print('\n❌ Send error: $e');
    } finally {
      await conn.close();
    }
  }
}
