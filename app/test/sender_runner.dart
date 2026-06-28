import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../lib/core/identity/secure_storage.dart';
import '../lib/core/identity/keypair_manager.dart';
import '../lib/core/storage/local_database.dart';
import '../lib/core/transfer/resume_state_store.dart';
import '../lib/core/transfer/transfer_manager.dart';
import '../lib/core/transport/lan_connection_manager.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('Run Sender Client', () async {
    final storage = InMemorySecureStorage();
    final identity = await KeypairManager.init(storage);

    final contactsDb = LocalDatabase(dbPath: 'cli_contacts.db');
    await contactsDb.init();

    final resumeDb = ResumeStateStore(dbPath: 'cli_transfers.db');
    await resumeDb.init();

    final peerDummyId = 'peer-device-id';
    final peerDummyPubKey = identity.publicKeyHex;

    final connectionManager = LanConnectionManager(
      identityManager: identity,
      getTrustedPublicKey: (id) async => peerDummyPubKey,
    );

    // Read target IP from config file, default to 127.0.0.1
    String targetIp = '127.0.0.1';
    final ipFile = File('target_ip.txt');
    if (await ipFile.exists()) {
      targetIp = (await ipFile.readAsString()).trim();
    }

    // Ensure we have a file to send
    final file = File('test_file.txt');
    if (!await file.exists()) {
      await file.writeAsString('Hello! This is a test file streamed securely via Flashy P2P local transport.');
    }

    print('Connecting to receiver at $targetIp:9999...');
    final conn = await connectionManager.connectToPeer(
      ipAddress: targetIp,
      port: 9999,
      peerDeviceId: peerDummyId,
    );
    print('🔒 Mutual authentication handshake successful!');

    final sender = TransferManager(resumeStore: resumeDb);
    sender.sendProgress.listen((manifest) {
      print('Chunks sent: ${manifest.chunksSent} / ${manifest.totalChunks}');
    });

    print('Streaming file ${file.path}...');
    await sender.sendFile(conn, file.path);
    print('🎉 File sent successfully!');

    await conn.close();
  });
}
