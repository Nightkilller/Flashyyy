import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flashy/core/identity/secure_storage.dart';
import 'package:flashy/core/identity/keypair_manager.dart';
import 'package:flashy/core/storage/local_database.dart';
import 'package:flashy/core/signaling/signaling_client.dart';
import 'package:flashy/core/pairing/pairing_service.dart';

void main() {
  late HttpServer mockServer;
  late List<WebSocket> clients;
  final Map<String, WebSocket> deviceConnections = {};
  final Map<String, String> activeTokens = {}; // token -> deviceIdA
  final Map<String, String> pairingRequestsMap = {}; // token -> deviceIdB

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    clients = [];
    deviceConnections.clear();
    activeTokens.clear();
    pairingRequestsMap.clear();

    // Spawn mock signaling server on localhost
    mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    mockServer.listen((HttpRequest request) async {
      if (request.uri.path == '/api/pairing/token' && request.method == 'POST') {
        // HTTP Token Endpoint
        final bodyBytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        final bodyString = utf8.decode(bodyBytes);
        final body = jsonDecode(bodyString) as Map<String, dynamic>;
        final deviceId = body['deviceId'] as String;

        final token = 'token-${DateTime.now().millisecondsSinceEpoch}';
        activeTokens[token] = deviceId;

        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'token': token}));
        await request.response.close();
      } else if (request.uri.path == '/') {
        // WebSocket connection upgrade
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final ws = await WebSocketTransformer.upgrade(request);
          clients.add(ws);
          
          ws.listen((message) {
            final data = jsonDecode(message as String) as Map<String, dynamic>;
            final action = data['action'] as String;
            final payload = data['payload'] as Map<String, dynamic>;

            if (action == 'register') {
              final deviceId = payload['deviceId'] as String;
              deviceConnections[deviceId] = ws;
            } else if (action == 'pairingRequest') {
              final token = payload['token'] as String;
              final hostDeviceId = activeTokens[token];
              if (hostDeviceId != null) {
                pairingRequestsMap[token] = payload['deviceId'] as String;
                final hostWs = deviceConnections[hostDeviceId];
                hostWs?.add(jsonEncode({
                  'action': 'pairingRequest',
                  'payload': payload,
                }));
              }
            } else if (action == 'pairingResponse') {
              final token = payload['token'] as String;
              final deviceIdB = pairingRequestsMap[token];
              if (deviceIdB != null) {
                final clientBWs = deviceConnections[deviceIdB];
                clientBWs?.add(jsonEncode({
                  'action': 'pairingResponse',
                  'payload': payload,
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

  group('Pairing Integration Tests', () {
    test('Device A and Device B complete pairing handshake successfully', () async {
      final signalingHttpUrl = 'http://localhost:${mockServer.port}';
      final signalingWsUrl = Uri.parse('ws://localhost:${mockServer.port}');

      final tempDir = await Directory.systemTemp.createTemp('flashy_pairing_integration_');
      
      try {
        // ─── Setup Device A ───
        final storageA = InMemorySecureStorage();
        final identityA = await KeypairManager.init(storageA, customDeviceName: 'Device A');
        final dbA = LocalDatabase(dbPath: '${tempDir.path}/dbA.db');
        await dbA.init();

        final clientA = SignalingClient(serverUri: signalingWsUrl, identityManager: identityA);
        await clientA.connect();
        final pairingA = PairingService(identityManager: identityA, signalingClient: clientA, database: dbA);

        // ─── Setup Device B ───
        final storageB = InMemorySecureStorage();
        final identityB = await KeypairManager.init(storageB, customDeviceName: 'Device B');
        final dbB = LocalDatabase(dbPath: '${tempDir.path}/dbB.db');
        await dbB.init();

        final clientB = SignalingClient(serverUri: signalingWsUrl, identityManager: identityB);
        await clientB.connect();
        final pairingB = PairingService(identityManager: identityB, signalingClient: clientB, database: dbB);

        // ─── Execute Handshake ───
        final completerA = Completer<bool>();
        final completerB = Completer<bool>();

        // 1. Device A starts pairing host, generates QR payload
        final qrPayload = await pairingA.startPairingHost(signalingHttpUrl, (success, peerName) {
          expect(peerName, 'Device B');
          completerA.complete(success);
        });

        expect(qrPayload, startsWith('flashy://pair'));

        // 2. Device B scans QR and initiates pairing request
        await pairingB.scanAndPair(qrPayload, (success, peerName) {
          expect(peerName, 'Device A');
          completerB.complete(success);
        });

        // 3. Await completion callbacks on both sides
        final results = await Future.wait([
          completerA.future.timeout(const Duration(seconds: 5)),
          completerB.future.timeout(const Duration(seconds: 5)),
        ]);

        expect(results[0], isTrue);
        expect(results[1], isTrue);

        // 4. Verify SQLite databases contain paired contacts
        final contactsA = await dbA.getContacts();
        final contactsB = await dbB.getContacts();

        expect(contactsA.length, 1);
        expect(contactsA[0]['device_id'], identityB.identity.deviceId);
        expect(contactsA[0]['device_name'], 'Device B');
        expect(contactsA[0]['public_key'], identityB.publicKeyHex);

        expect(contactsB.length, 1);
        expect(contactsB[0]['device_id'], identityA.identity.deviceId);
        expect(contactsB[0]['device_name'], 'Device A');
        expect(contactsB[0]['public_key'], identityA.publicKeyHex);

        // Cleanup clients
        await clientA.dispose();
        await clientB.dispose();
        await dbA.close();
        await dbB.close();
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}
