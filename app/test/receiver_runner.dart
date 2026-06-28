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

  test('Run Receiver Socket Server', () async {
    final storage = InMemorySecureStorage();
    final identity = await KeypairManager.init(storage);

    final contactsDb = LocalDatabase(dbPath: 'cli_contacts.db');
    await contactsDb.init();

    final resumeDb = ResumeStateStore(dbPath: 'cli_transfers.db');
    await resumeDb.init();

    // Trust self/local identity keys for testing
    final peerDummyId = 'peer-device-id';
    final peerDummyPubKey = identity.publicKeyHex;
    await contactsDb.addContact(
      deviceId: peerDummyId,
      deviceName: 'Sender Link',
      publicKey: peerDummyPubKey,
    );

    final connectionManager = LanConnectionManager(
      identityManager: identity,
      getTrustedPublicKey: (id) async => peerDummyPubKey,
    );

    final secureServer = await connectionManager.startServer(port: 9999);
    print('\n=============================================');
    print('🟢 FLASHY RECEIVER SOCKET LISTENING ON PORT 9999');
    print('   To connect to this laptop from another device, use IP:');
    // Print local network IPs
    final interfaces = await NetworkInterface.list();
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4) {
          print('   👉 ${addr.address}');
        }
      }
    }
    print('=============================================\n');

    final socket = await secureServer.first;
    print('Connection received! Executing handshake...');
    
    final conn = await connectionManager.handleIncomingConnection(socket);
    print('🔒 Mutual authentication handshake successful!');

    final receiver = TransferManager(resumeStore: resumeDb);
    receiver.receiveProgress.listen((manifest) {
      print('Chunks received: ${manifest.chunksReceived} / ${manifest.totalChunks}');
    });

    final downloadDir = Directory('downloads');
    if (!await downloadDir.exists()) {
      await downloadDir.create();
    }

    await receiver.receiveFiles(conn, downloadDir.path);
    print('🎉 File received successfully and saved to downloads/');
    
    await conn.close();
    await secureServer.close();
  });
}
