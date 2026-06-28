import 'dart:convert';
import 'dart:io';

import '../identity/keypair_manager.dart';
import 'session_store.dart';

/// Service to handle email code verification API calls with the signaling server.
class AuthService {
  final String signalingHttpUrl;
  final KeypairManager identityManager;
  final SessionStore sessionStore;

  AuthService({
    required this.signalingHttpUrl,
    required this.identityManager,
    required this.sessionStore,
  });

  /// Step 1: Request a 6-digit login code sent to the user's email.
  Future<void> requestCode(String email) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$signalingHttpUrl/api/auth/request-code'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'email': email,
      }));

      final response = await request.close();
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        final error = jsonDecode(body)['error'] as String? ?? 'Failed to request code';
        throw HttpException(error);
      }
    } finally {
      client.close();
    }
  }

  /// Step 2: Submit the 6-digit code to verify ownership and obtain session token.
  Future<void> verifyCode(String email, String code) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$signalingHttpUrl/api/auth/verify-code'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'email': email,
        'code': code,
        'deviceId': identityManager.identity.deviceId,
        'deviceName': identityManager.identity.deviceName,
        'publicKey': identityManager.publicKeyHex,
      }));

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      final data = jsonDecode(responseBody) as Map<String, dynamic>;

      if (response.statusCode != 200) {
        final error = data['error'] as String? ?? 'Code verification failed';
        throw HttpException(error);
      }

      final userId = data['userId'] as String;
      final sessionToken = data['sessionToken'] as String;

      // Persist locally
      await sessionStore.saveSession(
        token: sessionToken,
        userId: userId,
        email: email,
      );
    } finally {
      client.close();
    }
  }

  /// Step 3: Logs out by deleting local credentials and revoking token on server.
  Future<void> logout() async {
    final token = sessionStore.sessionToken;
    if (token == null) return;

    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$signalingHttpUrl/api/auth/logout'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      
      final response = await request.close();
      // Even if server call fails, we still clear local session
      if (response.statusCode != 200) {
        // Log or handle error if needed
      }
    } catch (_) {
      // Ignore network errors for logout to guarantee local wipe
    } finally {
      client.close();
      await sessionStore.clearSession();
    }
  }
}
