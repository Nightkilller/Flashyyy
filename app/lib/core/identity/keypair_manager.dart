import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import 'device_identity.dart';
import 'secure_storage.dart';

/// Manages the device's cryptographic identity: generates/loads Ed25519 keys,
/// performs signing and verification, and securely stores the private key.
class KeypairManager {
  static const String _kPrivateKeyStoreKey = 'flashy_private_key';
  static const String _kDeviceIdStoreKey = 'flashy_device_id';
  static const String _kDeviceNameStoreKey = 'flashy_device_name';

  final SecureStorage _secureStorage;
  final SimpleKeyPair _keyPair;
  final DeviceIdentity _identity;
  final Uint8List publicKeyBytes;

  KeypairManager._(this._secureStorage, this._keyPair, this._identity, this.publicKeyBytes);

  /// Getter for the public key bytes as a hex string.
  String get publicKeyHex => hex.encode(publicKeyBytes);

  /// Getter for the device identity.
  DeviceIdentity get identity => _identity;

  /// Initializes the device identity and keypair.
  /// Loads from secure storage if they exist; otherwise, generates them fresh.
  static Future<KeypairManager> init(SecureStorage secureStorage, {String? customDeviceName}) async {
    final ed25519 = Ed25519();
    
    // 1. Load or generate private key
    String? privKeyHex = await secureStorage.read(key: _kPrivateKeyStoreKey);
    SimpleKeyPair keyPair;
    if (privKeyHex == null) {
      // Generate new keypair
      keyPair = await ed25519.newKeyPair();
      final privBytes = await keyPair.extractPrivateKeyBytes();
      await secureStorage.write(key: _kPrivateKeyStoreKey, value: hex.encode(privBytes));
    } else {
      // Re-create from stored private key
      final privBytes = hex.decode(privKeyHex);
      keyPair = await ed25519.newKeyPairFromSeed(privBytes);
    }

    final pubKey = await keyPair.extractPublicKey();
    final publicKeyBytes = Uint8List.fromList(pubKey.bytes);

    // 2. Load or generate device ID
    String? deviceId = await secureStorage.read(key: _kDeviceIdStoreKey);
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await secureStorage.write(key: _kDeviceIdStoreKey, value: deviceId);
    }

    // 3. Load or generate device name
    String? deviceName = await secureStorage.read(key: _kDeviceNameStoreKey);
    if (deviceName == null) {
      deviceName = customDeviceName ?? _getDefaultDeviceName();
      await secureStorage.write(key: _kDeviceNameStoreKey, value: deviceName);
    }

    final deviceType = _getDeviceType();
    final identity = DeviceIdentity(
      deviceId: deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
    );

    return KeypairManager._(secureStorage, keyPair, identity, publicKeyBytes);
  }

  /// Signs a message with the private key.
  Future<Uint8List> sign(Uint8List message) async {
    final ed25519 = Ed25519();
    final signature = await ed25519.sign(message, keyPair: _keyPair);
    return Uint8List.fromList(signature.bytes);
  }

  /// Verifies a signature against a message and public key.
  static Future<bool> verify(
    Uint8List message,
    Uint8List signature,
    Uint8List publicKey,
  ) async {
    final ed25519 = Ed25519();
    final simplePublicKey = SimplePublicKey(
      publicKey,
      type: KeyPairType.ed25519,
    );
    final sigObject = Signature(signature, publicKey: simplePublicKey);
    return await ed25519.verify(message, signature: sigObject);
  }

  /// Helper to get a human-readable default device name.
  static String _getDefaultDeviceName() {
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isLinux) return 'Linux PC';
    if (Platform.isAndroid) return 'Android Device';
    if (Platform.isIOS) return 'iOS Device';
    return 'Unknown Device';
  }

  /// Helper to detect the current platform category.
  static String _getDeviceType() {
    if (Platform.isAndroid || Platform.isIOS) {
      return 'mobile';
    }
    return 'desktop';
  }
}
