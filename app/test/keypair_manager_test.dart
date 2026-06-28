import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

import 'package:flashy/core/identity/secure_storage.dart';
import 'package:flashy/core/identity/keypair_manager.dart';

void main() {
  late SecureStorage secureStorage;

  setUp(() {
    secureStorage = InMemorySecureStorage();
  });

  group('KeypairManager Tests', () {
    test('generates identity and loads it from store', () async {
      // 1. First init: generates a new key pair
      final manager1 = await KeypairManager.init(secureStorage, customDeviceName: 'Test Phone');
      expect(manager1.publicKeyHex, isNotEmpty);
      expect(manager1.publicKeyBytes.length, 32);
      expect(manager1.identity.deviceName, 'Test Phone');
      expect(manager1.identity.deviceId, isNotEmpty);
      expect(manager1.identity.deviceType, 'desktop'); // Unit test environment runs as desktop

      final firstPublicKey = manager1.publicKeyHex;
      final firstDeviceId = manager1.identity.deviceId;

      // 2. Second init: should load the exact same details
      final manager2 = await KeypairManager.init(secureStorage);
      expect(manager2.publicKeyHex, firstPublicKey);
      expect(manager2.identity.deviceId, firstDeviceId);
      expect(manager2.identity.deviceName, 'Test Phone');
    });

    test('signs and verifies messages correctly', () async {
      final manager = await KeypairManager.init(secureStorage);
      
      final message = utf8.encode('Hello cryptographic world!');
      final signature = await manager.sign(Uint8List.fromList(message));

      expect(signature, isNotEmpty);
      expect(signature.length, 64); // Ed25519 signature is 64 bytes

      // Verify with manager's static verify method
      final isValid = await KeypairManager.verify(
        Uint8List.fromList(message),
        signature,
        manager.publicKeyBytes,
      );
      expect(isValid, isTrue);

      // Verify failure on tampered message
      final invalid = await KeypairManager.verify(
        Uint8List.fromList(utf8.encode('Hello cryptographic world?')),
        signature,
        manager.publicKeyBytes,
      );
      expect(invalid, isFalse);
    });
  });
}
