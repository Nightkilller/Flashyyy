import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

import 'package:flashy/core/identity/secure_storage.dart';
import 'package:flashy/core/identity/keypair_manager.dart';
import 'package:flashy/core/auth/session_store.dart';
import 'package:flashy/core/auth/auth_service.dart';
import 'package:flashy/core/signaling/signaling_client.dart';

void main() {
  late HttpServer mockServer;
  late List<WebSocket> clients;
  
  // In-memory server state for test replication
  final Map<String, String> activeCodes = {}; // email -> code
  final Map<String, Map<String, dynamic>> activeSessions = {}; // token -> { userId, deviceId }
  final Map<String, String> users = {}; // email -> userId
  final Map<String, Map<String, dynamic>> devices = {}; // deviceId -> deviceMap
  final Map<String, List<int>> rateLimitRequests = {}; // email -> timestamps
  final Map<String, WebSocket> deviceConnections = {};

  setUp(() async {
    clients = [];
    activeCodes.clear();
    activeSessions.clear();
    users.clear();
    devices.clear();
    rateLimitRequests.clear();
    deviceConnections.clear();

    // Start mock authentication and signaling server in-memory
    mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mockServer.listen((HttpRequest request) async {
      final path = request.uri.path;
      final method = request.method;

      if (path == '/api/auth/request-code' && method == 'POST') {
        final bodyBytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        final body = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
        final email = body['email'] as String;

        // Rate Limit implementation: max 5 requests
        final now = DateTime.now().millisecondsSinceEpoch;
        final timestamps = rateLimitRequests.putIfAbsent(email, () => []);
        timestamps.retainWhere((t) => now - t < 15 * 60 * 1000); // 15 mins

        if (timestamps.length >= 5) {
          request.response
            ..statusCode = HttpStatus.tooManyRequests
            ..write(jsonEncode({'error': 'Rate limit exceeded'}));
          await request.response.close();
          return;
        }

        timestamps.add(now);

        // Generate 6-digit code
        final code = '123456';
        activeCodes[email] = code;

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'message': 'Sent'}));
        await request.response.close();
      } else if (path == '/api/auth/verify-code' && method == 'POST') {
        final bodyBytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        final body = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
        final email = body['email'] as String;
        final code = body['code'] as String;
        final deviceId = body['deviceId'] as String;
        final deviceName = body['deviceName'] as String;
        final publicKey = body['publicKey'] as String;

        if (activeCodes[email] != code) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..write(jsonEncode({'error': 'Invalid code'}));
          await request.response.close();
          return;
        }

        // Get or create user
        final userId = users.putIfAbsent(email, () => 'user-id-${email.split('@')[0]}');

        // Link device
        devices[deviceId] = {
          'id': deviceId,
          'deviceName': deviceName,
          'publicKey': publicKey,
          'userId': userId,
        };

        // Issue session token
        final token = 'session-token-$deviceId';
        activeSessions[token] = {
          'userId': userId,
          'deviceId': deviceId,
        };

        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'userId': userId,
            'sessionToken': token,
          }));
        await request.response.close();
      } else if (path == '/api/auth/logout' && method == 'POST') {
        final authHeader = request.headers.value(HttpHeaders.authorizationHeader);
        if (authHeader != null && authHeader.startsWith('Bearer ')) {
          final token = authHeader.substring(7);
          activeSessions.remove(token);
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode({'message': 'Logged out'}));
        await request.response.close();
      } else if (path == '/') {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final ws = await WebSocketTransformer.upgrade(request);
          clients.add(ws);

          ws.listen((message) {
            final data = jsonDecode(message as String) as Map<String, dynamic>;
            final action = data['action'] as String;
            final payload = data['payload'] as Map<String, dynamic>;

            if (action == 'register') {
              final deviceId = payload['deviceId'] as String;
              final sessionToken = payload['sessionToken'] as String?;
              
              deviceConnections[deviceId] = ws;

              if (sessionToken != null && activeSessions.containsKey(sessionToken)) {
                final session = activeSessions[sessionToken]!;
                devices[deviceId]?['userId'] = session['userId'];
              }
            } else if (action == 'getLinkedDevices') {
              // Find matching userId
              final deviceId = deviceConnections.entries
                  .firstWhere((e) => e.value == ws)
                  .key;
              final userId = devices[deviceId]?['userId'] as String?;
              
              if (userId != null) {
                // Return all other devices linked to this user
                final otherDevices = devices.values
                    .where((d) => d['userId'] == userId && d['id'] != deviceId)
                    .toList();
                
                ws.add(jsonEncode({
                  'action': 'linkedDevices',
                  'payload': {'devices': otherDevices}
                }));
              }
            }
          });
        }
      }
    });
  });

  tearDown(() async {
    for (final ws in clients) {
      await ws.close();
    }
    await mockServer.close();
  });

  group('Authentication Integration Tests', () {
    test('User logins in with email, links two devices, fetches devices, and logs out', () async {
      final signalingHttpUrl = 'http://localhost:${mockServer.port}';
      final signalingWsUrl = Uri.parse('ws://localhost:${mockServer.port}');

      final storageA = InMemorySecureStorage();
      final identityA = await KeypairManager.init(storageA, customDeviceName: 'Aditya iPhone');
      final sessionStoreA = SessionStore(storageA);
      final authA = AuthService(
        signalingHttpUrl: signalingHttpUrl,
        identityManager: identityA,
        sessionStore: sessionStoreA,
      );

      final storageB = InMemorySecureStorage();
      final identityB = await KeypairManager.init(storageB, customDeviceName: 'Aditya Mac');
      final sessionStoreB = SessionStore(storageB);
      final authB = AuthService(
        signalingHttpUrl: signalingHttpUrl,
        identityManager: identityB,
        sessionStore: sessionStoreB,
      );

      // 1. Device A requests code and verifies it
      await authA.requestCode('aditya@example.com');
      expect(activeCodes['aditya@example.com'], '123456');

      await authA.verifyCode('aditya@example.com', '123456');
      expect(sessionStoreA.isLoggedIn, isTrue);
      expect(sessionStoreA.sessionToken, 'session-token-${identityA.identity.deviceId}');

      // 2. Enforce email code request limit: 5 requests allowed, 6th fails
      for (var i = 0; i < 4; i++) {
        await authA.requestCode('aditya@example.com'); // Requests 2, 3, 4, 5
      }
      expect(
        () => authA.requestCode('aditya@example.com'), // 6th request
        throwsA(isA<HttpException>()),
      );

      // 3. Device B requests code and verifies it (links to same account)
      await authB.requestCode('sibling@example.com'); // Fresh email so no rate limit conflict
      activeCodes['aditya@example.com'] = '123456'; // Reset active code for verification
      await authB.verifyCode('aditya@example.com', '123456');
      expect(sessionStoreB.isLoggedIn, isTrue);

      // 4. WebSocket connection & fetching linked devices
      final clientA = SignalingClient(serverUri: signalingWsUrl, identityManager: identityA);
      await clientA.connect();
      
      // Snd registration with sessionToken
      clientA.send('register', {
        'deviceId': identityA.identity.deviceId,
        'deviceName': identityA.identity.deviceName,
        'publicKey': identityA.publicKeyHex,
        'sessionToken': sessionStoreA.sessionToken,
      });

      final clientB = SignalingClient(serverUri: signalingWsUrl, identityManager: identityB);
      await clientB.connect();
      clientB.send('register', {
        'deviceId': identityB.identity.deviceId,
        'deviceName': identityB.identity.deviceName,
        'publicKey': identityB.publicKeyHex,
        'sessionToken': sessionStoreB.sessionToken,
      });

      // Fetch linked devices on A
      final completer = Completer<List<dynamic>>();
      final sub = clientA.incomingMessages.listen((msg) {
        if (msg['action'] == 'linkedDevices') {
          completer.complete(msg['payload']['devices'] as List<dynamic>);
        }
      });

      clientA.send('getLinkedDevices', {});

      final otherDevices = await completer.future.timeout(const Duration(seconds: 3));
      expect(otherDevices.length, 1);
      expect(otherDevices[0]['id'], identityB.identity.deviceId);
      expect(otherDevices[0]['deviceName'], 'Aditya Mac');

      await sub.cancel();

      // 5. Logout Device A and verify revocation
      await authA.logout();
      expect(sessionStoreA.isLoggedIn, isFalse);
      expect(activeSessions.containsKey('session-token-${identityA.identity.deviceId}'), isFalse);

      await clientA.dispose();
      await clientB.dispose();
    });
  });
}
