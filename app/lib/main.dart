import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

import 'core/identity/secure_storage.dart';
import 'core/identity/keypair_manager.dart';
import 'core/storage/local_database.dart';
import 'core/transfer/resume_state_store.dart';
import 'core/transfer/transfer_manager.dart';
import 'core/discovery/lan_discovery_service.dart';
import 'core/transport/lan_connection_manager.dart';
import 'core/transport/signaling_connection.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/session_store.dart';
import 'core/signaling/signaling_client.dart';
import 'core/transport/tls_connection.dart';
import 'core/transport/connection.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FlashyApp());
}

class FlashyApp extends StatelessWidget {
  const FlashyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flashy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1), // Electric Indigo Accent
          brightness: Brightness.dark,
          background: const Color(0xFF0F172A), // Slate Dark Background
          surface: const Color(0xFF1E293B), // Card Slate Surface
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.bold),
          bodyMedium: TextStyle(fontFamily: 'Inter'),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Services State
  bool _initialized = false;
  String _initError = '';
  late KeypairManager _identity;
  late LocalDatabase _contactsDb;
  late ResumeStateStore _resumeDb;
  late LanDiscoveryService _discovery;
  late LanConnectionManager _connectionManager;
  late SessionStore _sessionStore;
  late AuthService _authService;
  SignalingClient? _signalingClient;
  StreamSubscription<Map<String, dynamic>>? _signalingSubscription;

  // Cloud synced devices
  List<Map<String, dynamic>> _cloudDevices = [];
  final Set<String> _activeCloudTransfers = {};

  // Configuration settings (for easier multi-device LAN testing)
  String _signalingServerHost = 'localhost:3000';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    try {
      // 1. Storage & Identity
      final storage = InMemorySecureStorage(); // clean fallback for testing platforms
      _identity = await KeypairManager.init(storage);

      // 2. Databases
      _contactsDb = LocalDatabase();
      await _contactsDb.init();

      _resumeDb = ResumeStateStore();
      await _resumeDb.init();

      _sessionStore = SessionStore(storage);
      await _sessionStore.loadSession();

      // 3. AuthService
      _authService = AuthService(
        signalingHttpUrl: 'http://$_signalingServerHost',
        identityManager: _identity,
        sessionStore: _sessionStore,
      );

      // 4. LAN Server Setup (binds to a dynamically allocated OS port)
      _connectionManager = LanConnectionManager(
        identityManager: _identity,
        getTrustedPublicKey: (id) async {
          // Cross-link: look up paired devices in DB
          final contacts = await _contactsDb.getContacts();
          for (final c in contacts) {
            if (c['device_id'] == id) {
              return c['public_key'] as String;
            }
          }
          // Also check linked cloud devices
          for (final d in _cloudDevices) {
            if (d['id'] == id) {
              return d['public_key'] as String;
            }
          }
          return null;
        },
      );

      final secureServer = await _connectionManager.startServer(port: 9999);

      // 5. LAN Discovery Service
      _discovery = LanDiscoveryService();
      _discovery.startListening();
      _discovery.startAdvertising(
        deviceId: _identity.identity.deviceId,
        deviceName: _identity.identity.deviceName,
        port: secureServer.port,
      );

      // Listen for incoming LAN server connections
      secureServer.listen((socket) async {
        try {
          final conn = await _connectionManager.handleIncomingConnection(socket);
          _startReceiverTransfer(conn);
        } catch (e) {
          debugPrint('Failed incoming connection: $e');
        }
      });

      // 6. Connect Signaling WebSocket if logged in
      _connectSignaling();

      setState(() {
        _initialized = true;
      });
    } catch (e) {
      setState(() {
        _initError = e.toString();
      });
    }
  }

  void _connectSignaling() {
    if (_sessionStore.isLoggedIn) {
      _signalingSubscription?.cancel();
      _signalingClient?.disconnect();

      _signalingClient = SignalingClient(
        serverUri: Uri.parse('ws://$_signalingServerHost'),
        identityManager: _identity,
      );
      _signalingClient?.connect();

      // Listen to signaling message events (presence & cloud relays)
      _signalingSubscription = _signalingClient!.incomingMessages.listen((msg) {
        if (msg['action'] == 'linkedDevices') {
          final payload = msg['payload'] as Map<String, dynamic>;
          setState(() {
            _cloudDevices = List<Map<String, dynamic>>.from(payload['devices'] as List);
          });
        } else if (msg['action'] == 'presenceUpdate') {
          _requestLinkedDevices();
        } else if (msg['action'] == 'relay') {
          final payload = msg['payload'] as Map<String, dynamic>;
          final senderId = payload['senderDeviceId'] as String;
          final signal = payload['signal'] as Map<String, dynamic>;

          if (signal['type'] == 'connectRequest') {
            if (!_activeCloudTransfers.contains(senderId)) {
              _activeCloudTransfers.add(senderId);
              _handleIncomingSignalingConnection(senderId).then((_) {
                _activeCloudTransfers.remove(senderId);
              }).catchError((_) {
                _activeCloudTransfers.remove(senderId);
              });
            }
          }
        }
      });

      // Delay briefly to allow socket to fully open before requesting list
      Future.delayed(const Duration(seconds: 1), _requestLinkedDevices);
    }
  }

  void _requestLinkedDevices() {
    if (_signalingClient?.isConnected == true) {
      _signalingClient?.send('getLinkedDevices', {});
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _discovery.stopListening();
    _discovery.stopAdvertising();
    _signalingSubscription?.cancel();
    _signalingClient?.disconnect();
    super.dispose();
  }

  // --- Handlers & Flows ---

  Future<void> _startSenderTransfer(LanDevice peer) async {
    // 1. Pick a file using FilePicker
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;
    final filePath = result.files.single.path!;

    // 2. Connect to the peer device
    TlsConnection? conn;
    try {
      conn = await _connectionManager.connectToPeer(
        ipAddress: peer.ipAddress,
        port: peer.port,
        peerDeviceId: peer.deviceId,
      );
    } catch (e) {
      _showErrorSnackBar('Connection failed: $e');
      return;
    }

    // 3. Initialize Sender Transfer Manager
    final sender = TransferManager(resumeStore: _resumeDb);
    final progressController = StreamController<TransferProgress>();

    _showProgressOverlay(
      title: 'Sending to ${peer.deviceName}',
      progressStream: progressController.stream,
      onComplete: () => _showSuccessSnackBar('File sent successfully!'),
      onError: (err) => _showErrorSnackBar('Send failed: $err'),
    );

    try {
      await sender.sendFile(
        conn,
        filePath,
        onProgress: (p) => progressController.add(p),
      );
    } catch (e) {
      progressController.addError(e);
      debugPrint('Error sending file: $e');
    } finally {
      await progressController.close();
      await conn.close();
    }
  }

  Future<void> _startCloudSenderTransfer(String peerDeviceId, String peerName) async {
    // 1. Pick file
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;
    final filePath = result.files.single.path!;

    if (_signalingClient == null || !_signalingClient!.isConnected) {
      _showErrorSnackBar('Signaling disconnected. Reconnecting...');
      return;
    }

    // 2. Create virtual Cloud Connection
    final conn = SignalingConnection(_signalingClient!, peerDeviceId);

    // Send trigger connection request to setup target
    _signalingClient!.sendRelayMessage(peerDeviceId, {
      'type': 'connectRequest',
    });

    // Brief delay to coordinate receivers
    await Future.delayed(const Duration(milliseconds: 500));

    // 3. Progress tracking
    final sender = TransferManager(resumeStore: _resumeDb);
    final progressController = StreamController<TransferProgress>();

    _showProgressOverlay(
      title: 'Sending to $peerName (Cloud)',
      progressStream: progressController.stream,
      onComplete: () => _showSuccessSnackBar('File sent successfully!'),
      onError: (err) => _showErrorSnackBar('Send failed: $err'),
    );

    try {
      // Execute standard client challenge-response over custom transport channel
      await _connectionManager.authenticateAsClient(conn, peerDeviceId);
      await sender.sendFile(
        conn,
        filePath,
        onProgress: (p) => progressController.add(p),
      );
    } catch (e) {
      progressController.addError(e);
      debugPrint('Cloud transfer failed: $e');
    } finally {
      await progressController.close();
      await conn.close();
    }
  }

  Future<void> _handleIncomingSignalingConnection(String senderId) async {
    if (_signalingClient == null) return;
    final conn = SignalingConnection(_signalingClient!, senderId);

    // Start progress tracker & receiver manifest settings
    final receiver = TransferManager(resumeStore: _resumeDb);
    final downloadsDir = await getTemporaryDirectory();
    final progressController = StreamController<TransferProgress>();

    _showProgressOverlay(
      title: 'Receiving File (Cloud)...',
      progressStream: progressController.stream,
      onComplete: () => _showSuccessSnackBar('File received successfully!'),
      onError: (err) => _showErrorSnackBar('Receive failed: $err'),
    );

    try {
      // Execute server challenge-response over custom transport channel
      await _connectionManager.authenticateAsServer(conn);
      await receiver.receiveFiles(
        conn,
        downloadsDir.path,
        onProgress: (p) => progressController.add(p),
      );
    } catch (e) {
      progressController.addError(e);
      debugPrint('Cloud receiving handshake failed: $e');
    } finally {
      await progressController.close();
      await conn.close();
    }
  }

  Future<void> _startReceiverTransfer(TlsConnection conn) async {
    // 1. Initialize Receiver Transfer Manager (receives in standard download directory)
    final receiver = TransferManager(resumeStore: _resumeDb);
    final downloadsDir = await getTemporaryDirectory(); // Fallback storage folder
    final progressController = StreamController<TransferProgress>();

    _showProgressOverlay(
      title: 'Receiving File...',
      progressStream: progressController.stream,
      onComplete: () => _showSuccessSnackBar('File received and saved!'),
      onError: (err) => _showErrorSnackBar('Receive failed: $err'),
    );

    try {
      await receiver.receiveFiles(
        conn,
        downloadsDir.path,
        onProgress: (p) => progressController.add(p),
      );
    } catch (e) {
      progressController.addError(e);
      debugPrint('Error receiving file: $e');
    } finally {
      await progressController.close();
      await conn.close();
    }
  }

  void _showProgressOverlay({
    required String title,
    required Stream<TransferProgress> progressStream,
    required VoidCallback onComplete,
    required Function(String) onError,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StreamBuilder<TransferProgress>(
          stream: progressStream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                Navigator.of(context).pop();
                onError(snapshot.error.toString());
              });
              return const SizedBox.shrink();
            }

            if (!snapshot.hasData) {
              return const AlertDialog(
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Preparing files...', style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              );
            }

            final progress = snapshot.data!;
            final value = progress.fraction;

            if (value >= 1.0) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                Navigator.of(context).pop();
                onComplete();
              });
            }

            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: value),
                  const SizedBox(height: 16),
                  Text(
                    '${(value * 100).toStringAsFixed(1)}% completed',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'File: ${progress.currentFileName}',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showSuccessSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.greenAccent),
            const SizedBox(width: 8),
            Text(msg),
          ],
        ),
        backgroundColor: const Color(0xFF1E293B),
      ),
    );
  }

  void _showErrorSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error, color: Colors.redAccent),
            const SizedBox(width: 8),
            Text(msg),
          ],
        ),
        backgroundColor: const Color(0xFF1E293B),
      ),
    );
  }

  // --- Screens & Widgets ---

  @override
  Widget build(BuildContext context) {
    if (_initError.isNotEmpty) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
                const SizedBox(height: 16),
                const Text('Initialization Error', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(_initError, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _initializeServices,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_initialized) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF6366F1)),
              SizedBox(height: 24),
              Text('Initializing Flashy engine...', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1).withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.flash_on, color: Color(0xFF6366F1)),
            ),
            const SizedBox(width: 10),
            const Text('Flashy', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF6366F1),
          labelColor: const Color(0xFF6366F1),
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(icon: Icon(Icons.share), text: 'Share'),
            Tab(icon: Icon(Icons.qr_code_2), text: 'Pairing'),
            Tab(icon: Icon(Icons.manage_accounts), text: 'Account'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildShareTab(),
          _buildPairingTab(),
          _buildAccountTab(),
        ],
      ),
    );
  }

  Widget _buildShareTab() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Own device info card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: const Color(0xFF6366F1).withOpacity(0.15),
                      child: const Icon(Icons.devices, color: Color(0xFF6366F1)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_identity.identity.deviceName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          Text('Device ID: ${_identity.identity.deviceId.substring(0, 18)}...', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Nearby Discovered Devices', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            // StreamBuilder listening to LAN devices
            StreamBuilder<List<LanDevice>>(
              stream: _discovery.discoveredDevices,
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const RadarScanner(),
                          const SizedBox(height: 24),
                          Text('Scanning local Wi-Fi for peers...', style: TextStyle(color: Colors.grey[500])),
                        ],
                      ),
                    ),
                  );
                }

                final devices = snapshot.data!;
                return ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final device = devices[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      color: const Color(0xFF1E293B),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF6366F1),
                          child: Icon(
                            device.deviceId.hashCode.isEven ? Icons.phone_android : Icons.laptop,
                            color: Colors.white,
                          ),
                        ),
                        title: Text(device.deviceName, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(device.ipAddress, style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF6366F1),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => _startSenderTransfer(device),
                          child: const Text('Send File'),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Cloud Linked Devices (Cross-Network)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                if (_sessionStore.isLoggedIn)
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: _requestLinkedDevices,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (!_sessionStore.isLoggedIn)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Center(
                    child: Text(
                      'Log in on the Account tab to enable cloud transfers across different networks.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[400], fontSize: 13),
                    ),
                  ),
                ),
              )
            else if (_cloudDevices.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Center(
                    child: Text('No other online linked devices. Tap refresh to check.', style: TextStyle(color: Colors.grey[400])),
                  ),
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _cloudDevices.length,
                itemBuilder: (context, index) {
                  final device = _cloudDevices[index];
                  final isOnline = device['isOnline'] as bool? ?? false;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    color: const Color(0xFF1E293B),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isOnline ? Colors.greenAccent.withOpacity(0.2) : Colors.grey.withOpacity(0.2),
                        child: Icon(
                          Icons.cloud,
                          color: isOnline ? Colors.greenAccent : Colors.grey,
                        ),
                      ),
                      title: Text(device['device_name'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        isOnline ? 'Online (Cloud)' : 'Offline',
                        style: TextStyle(color: isOnline ? Colors.greenAccent : Colors.grey, fontSize: 12),
                      ),
                      trailing: isOnline
                          ? ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF6366F1),
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () => _startCloudSenderTransfer(device['id'] as String, device['device_name'] as String),
                              child: const Text('Send File'),
                            )
                          : null,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPairingTab() {
    final pairingString = 'flashy-pair:${_identity.identity.deviceId}:${_identity.publicKeyHex}:${_identity.identity.deviceName}';
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Text('Your Pairing QR Code', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Let a friend scan this to link devices', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: pairingString,
                version: QrVersions.auto,
                size: 200.0,
                gapless: false,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan Peer Code'),
              onPressed: _openQRScanner,
            ),
            const SizedBox(height: 32),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Paired Devices & Contacts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _contactsDb.getContacts(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Center(
                        child: Text('No paired devices yet.', style: TextStyle(color: Colors.grey[400])),
                      ),
                    ),
                  );
                }

                final contacts = snapshot.data!;
                return ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: contacts.length,
                  itemBuilder: (context, index) {
                    final contact = contacts[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.person, color: Color(0xFF6366F1)),
                        title: Text(contact['device_name'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(
                          'ID: ${(contact['device_id'] as String).substring(0, 18)}...',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.redAccent),
                          onPressed: () async {
                            await _contactsDb.deleteContact(contact['device_id'] as String);
                            setState(() {}); // refresh DB views
                          },
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openQRScanner() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Scan QR Code')),
          body: MobileScanner(
            onDetect: (capture) async {
              final barcodes = capture.barcodes;
              if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                final rawValue = barcodes.first.rawValue!;
                if (rawValue.startsWith('flashy-pair:')) {
                  final parts = rawValue.split(':');
                  if (parts.length >= 4) {
                    final peerId = parts[1];
                    final peerKey = parts[2];
                    final peerName = parts[3];

                    await _contactsDb.addContact(
                      deviceId: peerId,
                      deviceName: peerName,
                      publicKey: peerKey,
                    );
                    
                    if (mounted) {
                      Navigator.of(context).pop();
                      _showSuccessSnackBar('Paired with $peerName!');
                      setState(() {}); // refresh DB lists
                    }
                  }
                }
              }
            },
          ),
        ),
      ),
    );
  }

  Widget _buildAccountTab() {
    final emailController = TextEditingController(text: _sessionStore.userEmail ?? '');
    final codeController = TextEditingController();
    bool codeSent = false;

    return StatefulBuilder(
      builder: (context, setState) {
        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Account Device Syncing', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  'Link multiple devices together using your email. Automatically syncs trust keys across all your desktops and mobiles.',
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                ),
                const SizedBox(height: 24),
                if (_sessionStore.isLoggedIn) ...[
                  Card(
                    color: const Color(0xFF1E293B),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.cloud_done, color: Colors.greenAccent),
                              SizedBox(width: 8),
                              Text('Device Linked Successfully', style: TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text('Logged in as: ${_sessionStore.userEmail}', style: const TextStyle(fontSize: 15)),
                          const SizedBox(height: 4),
                          Text('User ID: ${_sessionStore.userId}', style: TextStyle(color: Colors.grey[400], fontSize: 12)),
                          const SizedBox(height: 24),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                            onPressed: () async {
                              await _sessionStore.clearSession();
                              _signalingSubscription?.cancel();
                              _signalingClient?.disconnect();
                              _signalingClient = null;
                              _cloudDevices = [];
                              setState(() {});
                              this.setState(() {}); // refresh outer views
                            },
                            child: const Text('Unlink Account'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ] else ...[
                  TextField(
                    controller: emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email Address',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.email),
                    ),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 16),
                  if (codeSent) ...[
                    TextField(
                      controller: codeController,
                      decoration: const InputDecoration(
                        labelText: '6-digit Verification Code',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.lock),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6366F1),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () async {
                          try {
                            await _authService.verifyCode(emailController.text.trim(), codeController.text.trim());
                            _connectSignaling();
                            setState(() {});
                            this.setState(() {}); // refresh outer state
                            _showSuccessSnackBar('Logged in successfully!');
                          } catch (e) {
                            _showErrorSnackBar(e.toString());
                          }
                        },
                        child: const Text('Verify and Link'),
                      ),
                    ),
                  ] else ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6366F1),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () async {
                          try {
                            await _authService.requestCode(emailController.text.trim());
                            setState(() {
                              codeSent = true;
                            });
                            _showSuccessSnackBar('Verification code sent to email!');
                          } catch (e) {
                            _showErrorSnackBar(e.toString());
                          }
                        },
                        child: const Text('Send Verification Code'),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 16),
                const Text('Signaling Server Host Settings', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(
                  controller: TextEditingController(text: _signalingServerHost),
                  decoration: const InputDecoration(
                    labelText: 'Signaling Server IP:Port',
                    border: OutlineInputBorder(),
                    helperText: 'e.g., 192.168.1.50:8080 (Set to local signaling IP for multi-device testing)',
                  ),
                  onChanged: (val) {
                    setState(() {
                      _signalingServerHost = val.trim();
                      _authService = AuthService(
                        signalingHttpUrl: 'http://$_signalingServerHost',
                        identityManager: _identity,
                        sessionStore: _sessionStore,
                      );
                    });
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// --- radar animation widget ---
class RadarScanner extends StatefulWidget {
  const RadarScanner({super.key});

  @override
  State<RadarScanner> createState() => _RadarScannerState();
}

class _RadarScannerState extends State<RadarScanner> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: RadarPainter(_controller.value),
          size: const Size(150, 150),
        );
      },
    );
  }
}

class RadarPainter extends CustomPainter {
  final double progress;
  RadarPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Draw rings expanding
    for (int i = 0; i < 3; i++) {
      final currentProgress = (progress + i / 3) % 1.0;
      final radius = maxRadius * currentProgress;
      final opacity = (1.0 - currentProgress) * 0.4;

      final paint = Paint()
        ..color = const Color(0xFF6366F1).withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      canvas.drawCircle(center, radius, paint);
    }

    // Draw solid center circle
    final centerPaint = Paint()
      ..color = const Color(0xFF6366F1)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 12, centerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
