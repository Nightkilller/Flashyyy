import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'secure_storage.dart';

/// Production implementation backed by platform-native secure storage.
class KeychainSecureStorage implements SecureStorage {
  final _storage = const FlutterSecureStorage(
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  @override
  Future<void> write({required String key, required String value}) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<String?> read({required String key}) async {
    return await _storage.read(key: key);
  }

  @override
  Future<void> delete({required String key}) async {
    await _storage.delete(key: key);
  }
}
