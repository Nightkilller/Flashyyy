import '../identity/secure_storage.dart';

/// Persists user authentication state (session token, user ID, email) in SecureStorage.
class SessionStore {
  static const String _kSessionTokenKey = 'flashy_session_token';
  static const String _kUserIdKey = 'flashy_user_id';
  static const String _kUserEmailKey = 'flashy_user_email';

  final SecureStorage _secureStorage;
  
  String? _sessionToken;
  String? _userId;
  String? _userEmail;

  SessionStore(this._secureStorage);

  /// Load session details from secure storage on startup.
  Future<void> loadSession() async {
    _sessionToken = await _secureStorage.read(key: _kSessionTokenKey);
    _userId = await _secureStorage.read(key: _kUserIdKey);
    _userEmail = await _secureStorage.read(key: _kUserEmailKey);
  }

  /// Whether the user is currently logged in.
  bool get isLoggedIn => _sessionToken != null;

  String? get sessionToken => _sessionToken;
  String? get userId => _userId;
  String? get userEmail => _userEmail;

  /// Saves session details to secure storage.
  Future<void> saveSession({
    required String token,
    required String userId,
    required String email,
  }) async {
    _sessionToken = token;
    _userId = userId;
    _userEmail = email;

    await _secureStorage.write(key: _kSessionTokenKey, value: token);
    await _secureStorage.write(key: _kUserIdKey, value: userId);
    await _secureStorage.write(key: _kUserEmailKey, value: email);
  }

  /// Clears session details from secure storage (logout).
  Future<void> clearSession() async {
    _sessionToken = null;
    _userId = null;
    _userEmail = null;

    await _secureStorage.delete(key: _kSessionTokenKey);
    await _secureStorage.delete(key: _kUserIdKey);
    await _secureStorage.delete(key: _kUserEmailKey);
  }
}
