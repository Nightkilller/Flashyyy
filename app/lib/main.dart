import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:google_fonts/google_fonts.dart';
import 'package:open_filex/open_filex.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'core/identity/keypair_manager.dart';
import 'core/identity/keychain_secure_storage.dart';
import 'core/storage/local_database.dart';
import 'core/transfer/resume_state_store.dart';
import 'core/transfer/transfer_manager.dart';
import 'core/transfer/file_chunker.dart';
import 'core/discovery/lan_discovery_service.dart';
import 'core/transport/lan_connection_manager.dart';
import 'core/transport/signaling_connection.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/session_store.dart';
import 'core/auth/firebase_auth_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'core/signaling/signaling_client.dart';
import 'core/transport/tls_connection.dart';

// ═══════════════════════════════════════════════════════
// Design tokens — matching Lovable "Paytin" palette
// ═══════════════════════════════════════════════════════
class _C {
  // Core palette
  static const background = Color(0xFFF2F7E8);  // warm cream-lime
  static const foreground = Color(0xFF1A2E1A);  // deep forest text
  static const ink        = Color(0xFF1E3320);  // dark green cards
  static const primary    = Color(0xFFB8E636);  // lime accent
  static const primaryGlow= Color(0xFFD4F47A);  // lighter lime
  static const card       = Colors.white;
  static const muted      = Color(0xFF6B7B6B);  // muted text
  static const success    = Color(0xFF4ADE80);  // green dots
  static const border     = Color(0x1A1E3320);  // 10% ink
  static const destructive= Color(0xFFEF4444);
  static const secondaryBg= Color(0xFFF0F5E4);  // light lime card bg
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

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
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _C.primary,
          brightness: Brightness.light,
          surface: _C.card,
          primary: _C.primary,
        ),
        scaffoldBackgroundColor: _C.background,
        textTheme: GoogleFonts.plusJakartaSansTextTheme(),
        cardTheme: CardThemeData(
          color: _C.card,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: _C.border),
          ),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// ═══════════════════════════════════════════════════════
// Main screen with all backend wiring
// ═══════════════════════════════════════════════════════
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  // Navigation
  String _tab = 'home';
  String _filter = 'out'; // 'in' or 'out'
  bool _accountOpen = false;
  String? _selectedFilePath;
  bool _skippedLogin = false;
  List<Map<String, dynamic>> _transferHistory = [];
  String _historyFilter = 'all'; // 'all', 'send', 'receive'
  int _sentTodayCount = 0;
  int _receivedCount = 0;

  // Services State
  bool _initialized = false;
  bool _servicesInitialized = false;
  String _initError = '';
  late KeypairManager _identity;
  late LocalDatabase _contactsDb;
  late ResumeStateStore _resumeDb;
  late LanDiscoveryService _discovery;
  late LanConnectionManager _connectionManager;
  late SessionStore _sessionStore;
  late AuthService _authService;
  late FirebaseAuthService _firebaseAuth;
  SignalingClient? _signalingClient;
  StreamSubscription<Map<String, dynamic>>? _signalingSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _firebaseDevicesSubscription;
  late final AnimationController _loginWaveController;

  // Cloud synced devices
  List<Map<String, dynamic>> _cloudDevices = [];
  final Set<String> _activeCloudTransfers = {};
  Set<String> _pairedDeviceIds = {};

  // Configuration
  String _signalingServerHost = 'localhost:3000';

  // Account login state
  late final TextEditingController _emailController;
  late final TextEditingController _codeController;
  late final TextEditingController _manualPairController;
  bool _codeSent = false;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController();
    _codeController = TextEditingController();
    _manualPairController = TextEditingController();
    _loginWaveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat(reverse: true);
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    try {
      // Initialize Firebase — catch duplicate-app (Android auto-inits via google-services plugin)
      try {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      } catch (e) {
        // Duplicate-app is expected on Android — Firebase was already auto-initialized
        if (!e.toString().contains('duplicate-app')) {
          debugPrint('Firebase initialization failed: $e');
        }
      }

      // 1. Storage & Identity
      final storage = KeychainSecureStorage();
      _identity = await KeypairManager.init(storage);

      // 2. Databases
      _contactsDb = LocalDatabase();
      await _contactsDb.init();

      // Load initial paired devices
      final contacts = await _contactsDb.getContacts();
      _pairedDeviceIds = contacts.map((c) => c['device_id'] as String).toSet();

      _resumeDb = ResumeStateStore();
      await _resumeDb.init();
      await _loadTransferHistory();

      _sessionStore = SessionStore(storage);
      await _sessionStore.loadSession();
      if (_sessionStore.isLoggedIn && _sessionStore.userEmail != null) {
        _emailController.text = _sessionStore.userEmail!;
      }

      // 3. AuthService
      _authService = AuthService(
        signalingHttpUrl: 'http://$_signalingServerHost',
        identityManager: _identity,
        sessionStore: _sessionStore,
      );

      // Firebase Auth Service
      _firebaseAuth = FirebaseAuthService(sessionStore: _sessionStore);
      _firebaseAuth.setIdentityManager(_identity);

      // ── Session Persistence: Restore Firebase session on cold start ──
      // Firebase Auth persists sessions, but currentUser is null until
      // the auth state is restored. Try restoring now.
      final sessionRestored = await _firebaseAuth.tryRestoreSession();
      if (sessionRestored || _firebaseAuth.isSignedIn) {
        _skippedLogin = true; // Auto-skip login screen
      }

      // 4. LAN Server Setup
      _connectionManager = LanConnectionManager(
        identityManager: _identity,
        getTrustedPublicKey: (id) async {
          // Check locally paired contacts first
          final contacts = await _contactsDb.getContacts();
          for (final c in contacts) {
            if (c['device_id'] == id) return c['public_key'] as String;
          }
          // Then check cloud-synced devices (same-email auto-trust)
          for (final d in _cloudDevices) {
            if (d['id'] == id && d['public_key'] != null) return d['public_key'] as String;
          }
          return null;
        },
      );

      final secureServer = await _connectionManager.startServer(port: 9999);

      // 5. LAN Discovery Service
      _discovery = LanDiscoveryService();
      _discovery.start(
        deviceId: _identity.identity.deviceId,
        deviceName: _identity.identity.deviceName,
        port: secureServer.port,
      );

      // Listen for incoming LAN connections
      secureServer.listen((socket) async {
        try {
          final conn = await _connectionManager.handleIncomingConnection(
            socket,
            confirmPairingRequest: (deviceName, deviceId) async {
              return await _showPairingDialog(deviceName, deviceId);
            },
            onPairCompleted: (id, name, key) async {
              await _contactsDb.addContact(deviceId: id, deviceName: name, publicKey: key);
              _pairedDeviceIds.add(id);
              _showSuccessSnackBar('Mutually paired with $name!');
              setState(() {});
            },
          );
          _startReceiverTransfer(conn);
        } catch (e) {
          final errStr = e.toString();
          if (errStr.contains('Pairing connection complete')) {
            return;
          }
          debugPrint('Failed incoming connection: $e');
          if (errStr.contains('is not a trusted contact')) {
            final match = RegExp(r'Device ([a-zA-Z0-9\\-]+) is not').firstMatch(errStr);
            final deviceId = match?.group(1);
            String deviceName = 'Unpaired Device';
            if (deviceId != null) {
              final matchDevice = _discovery.currentDevices.firstWhere(
                (d) => d.deviceId == deviceId,
                orElse: () => LanDevice(
                  deviceId: deviceId,
                  deviceName: 'Unpaired Device',
                  ipAddress: '',
                  port: 0,
                  lastSeen: DateTime.now(),
                ),
              );
              deviceName = matchDevice.deviceName;
            }
            _showErrorSnackBar('Connection rejected: $deviceName is not paired. Please pair devices first!');
          }
        }
      });

      // 6. Connect Signaling WebSocket if logged in
      _connectSignaling();

      setState(() { _initialized = true; });
      _servicesInitialized = true;
    } catch (e) {
      setState(() { _initError = e.toString(); });
    }
  }

  void _connectSignaling() {
    if (_sessionStore.isLoggedIn) {
      // Connect signaling client for P2P connection relaying
      _signalingSubscription?.cancel();
      _signalingClient?.dispose();

      _signalingClient = SignalingClient(
        serverUri: Uri.parse('ws://$_signalingServerHost'),
        identityManager: _identity,
        sessionToken: _sessionStore.sessionToken,
      );
      _signalingClient?.connect();

      _signalingSubscription = _signalingClient!.incomingMessages.listen((msg) {
        if (msg['action'] == 'relay') {
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

      // Also listen to Firestore for real-time cloud device registry
      _firebaseDevicesSubscription?.cancel();
      _firebaseDevicesSubscription = _firebaseAuth.getMyDevicesStream().listen((devices) {
        setState(() {
          _cloudDevices = devices;
        });
      });

      // Mark device as online in Firebase
      _firebaseAuth.setDeviceOnline();
    }
  }

  void _requestLinkedDevices() {
    if (_signalingClient?.isConnected == true) {
      _signalingClient?.send('getLinkedDevices', {});
    }
  }


  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _manualPairController.dispose();
    _loginWaveController.dispose();
    if (_servicesInitialized) {
      _discovery.dispose();
      _firebaseAuth.setDeviceOffline();
    }
    _signalingSubscription?.cancel();
    _firebaseDevicesSubscription?.cancel();
    _signalingClient?.dispose();
    super.dispose();
  }

  // ── Transfer Handlers ──

  Future<void> _startSenderTransfer(LanDevice peer, {String? filePath}) async {
    final isPaired = await _contactsDb.isContactPaired(peer.deviceId);
    final isCloudLinked = _cloudDevices.any((d) => d['id'] == peer.deviceId);
    if (!isPaired && !isCloudLinked) {
      _showErrorSnackBar('Devices are not paired. Please scan the QR code under the "Pair & QR" tab on BOTH devices first to pair them!');
      return;
    }

    final String path;
    if (filePath != null) {
      path = filePath;
    } else {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.single.path == null) return;
      path = result.files.single.path!;
    }

    TlsConnection? conn;
    try {
      conn = await _connectionManager.connectToPeer(
        ipAddress: peer.ipAddress, port: peer.port, peerDeviceId: peer.deviceId,
      );
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('is not a trusted contact')) {
        _showErrorSnackBar('Connection failed: Both devices must scan each other\'s QR codes to pair!');
      } else if (errStr.contains('disconnected before replying to challenge')) {
        _showErrorSnackBar('Connection failed: The other device rejected the connection because you are not paired. Please scan their QR code to pair!');
      } else {
        _showErrorSnackBar('Connection failed: $e');
      }
      return;
    }

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
        path, 
        onProgress: (p) => progressController.add(p),
        peerDeviceName: peer.deviceName,
      );
    } catch (e) {
      progressController.addError(e);
      debugPrint('Error sending file: $e');
    } finally {
      await progressController.close();
      await conn.close();
      _loadTransferHistory();
    }
  }

  Future<void> _startCloudSenderTransfer(String peerDeviceId, String peerName, {String? filePath}) async {
    final String path;
    if (filePath != null) {
      path = filePath;
    } else {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.single.path == null) return;
      path = result.files.single.path!;
    }

    if (_signalingClient == null || !_signalingClient!.isConnected) {
      _showErrorSnackBar('Signaling disconnected. Reconnecting...');
      return;
    }

    final conn = SignalingConnection(_signalingClient!, peerDeviceId);
    _signalingClient!.sendRelayMessage(peerDeviceId, {'type': 'connectRequest'});
    await Future.delayed(const Duration(milliseconds: 500));

    final sender = TransferManager(resumeStore: _resumeDb);
    final progressController = StreamController<TransferProgress>();

    _showProgressOverlay(
      title: 'Sending to $peerName (Cloud)',
      progressStream: progressController.stream,
      onComplete: () => _showSuccessSnackBar('File sent successfully!'),
      onError: (err) => _showErrorSnackBar('Send failed: $err'),
    );

    try {
      await _connectionManager.authenticateAsClient(conn, peerDeviceId);
      await sender.sendFile(
        conn, 
        path, 
        onProgress: (p) => progressController.add(p),
        peerDeviceName: peerName,
      );
    } catch (e) {
      progressController.addError(e);
      debugPrint('Cloud transfer failed: $e');
    } finally {
      await progressController.close();
      await conn.close();
      _loadTransferHistory();
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = (math.log(bytes) / math.log(1024)).floor();
    if (i >= suffixes.length) i = suffixes.length - 1;
    return '${(bytes / math.pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  bool _isFileImage(String fileName) {
    final lower = fileName.toLowerCase();
    return lower.endsWith('.png') || 
           lower.endsWith('.jpg') || 
           lower.endsWith('.jpeg') || 
           lower.endsWith('.gif') || 
           lower.endsWith('.webp') ||
           lower.endsWith('.heic');
  }

  Future<Directory> _getDestinationDirectory() async {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir;
    } else if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download');
      if (await dir.exists()) {
        return dir;
      }
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) return extDir;
    } else if (Platform.isIOS) {
      return await getApplicationDocumentsDirectory();
    }
    return await getTemporaryDirectory();
  }

  Future<String> _getDeviceNameForId(String deviceId) async {
    final contacts = await _contactsDb.getContacts();
    for (final c in contacts) {
      if (c['device_id'] == deviceId) return c['device_name'] as String;
    }
    for (final d in _cloudDevices) {
      if (d['id'] == deviceId) return d['device_name'] as String;
    }
    for (final d in _discovery.currentDevices) {
      if (d.deviceId == deviceId) return d.deviceName;
    }
    return 'Unknown Device';
  }

  Future<String?> _showIncomingTransferDialog(TransferManifest manifest) async {
    final completer = Completer<String?>();
    final fileName = manifest.files.isNotEmpty ? manifest.files.first.relativePath : 'Unknown';
    final totalSize = _formatBytes(manifest.totalBytes);
    
    String currentPath = await _getDestinationDirectory().then((dir) => dir.path);
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: _C.background,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: _C.primary.withOpacity(0.2), shape: BoxShape.circle),
                child: const Icon(Icons.download_for_offline_rounded, color: _C.primary),
              ),
              const SizedBox(width: 12),
              const Expanded(child: Text('Incoming File', style: TextStyle(fontWeight: FontWeight.w800))),
            ],
          ),
          content: StatefulBuilder(
            builder: (ctx, setDialogState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Do you want to accept this file?'),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _C.secondaryBg.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _C.border),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: _C.primary.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            _isFileImage(fileName) 
                                ? Icons.image_rounded 
                                : Icons.insert_drive_file_rounded, 
                            color: _C.primary, 
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 4),
                              Text('Size: $totalSize', style: TextStyle(color: _C.muted, fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.folder_open_rounded, size: 16, color: _C.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Save to: ...${currentPath.length > 20 ? currentPath.substring(currentPath.length - 20) : currentPath}',
                          style: TextStyle(color: _C.muted, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          String? selected;
                          if (Platform.isIOS) {
                            selected = await showDialog<String>(
                              context: context,
                              builder: (sheetCtx) => AlertDialog(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                backgroundColor: _C.background,
                                title: const Text('Select Location', style: TextStyle(fontWeight: FontWeight.bold)),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ListTile(
                                      leading: const Icon(Icons.folder_shared_rounded, color: _C.primary),
                                      title: const Text('App Documents (Persistent)'),
                                      subtitle: const Text('Visible in Files app'),
                                      onTap: () async {
                                        final dir = await getApplicationDocumentsDirectory();
                                        Navigator.of(sheetCtx).pop(dir.path);
                                      },
                                    ),
                                    const Divider(),
                                    ListTile(
                                      leading: const Icon(Icons.folder_zip_rounded, color: _C.primary),
                                      title: const Text('Temporary Folder'),
                                      subtitle: const Text('Will be cleared by system eventually'),
                                      onTap: () async {
                                        final dir = await getTemporaryDirectory();
                                        Navigator.of(sheetCtx).pop(dir.path);
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            );
                          } else {
                            selected = await FilePicker.platform.getDirectoryPath();
                          }
                          if (selected != null) {
                            setDialogState(() {
                              currentPath = selected!;
                            });
                          }
                        },
                        child: const Text('Change', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ],
              );
            }
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogCtx).pop();
                completer.complete(null);
              },
              child: Text('Decline', style: TextStyle(color: _C.destructive, fontWeight: FontWeight.w600)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogCtx).pop();
                completer.complete(currentPath);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _C.primary,
                foregroundColor: _C.ink,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                elevation: 0,
              ),
              child: const Text('Accept & Save', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        );
      },
    );
    return completer.future;
  }

  Future<void> _handleIncomingSignalingConnection(String senderId) async {
    if (_signalingClient == null) return;
    final conn = SignalingConnection(_signalingClient!, senderId);
    final receiver = TransferManager(resumeStore: _resumeDb);
    final downloadsDir = await _getDestinationDirectory();
    final peerName = await _getDeviceNameForId(senderId);
    String targetDir = downloadsDir.path;
    final progressController = StreamController<TransferProgress>();

    _showProgressOverlay(
      title: 'Receiving File (Cloud)...',
      progressStream: progressController.stream,
      onComplete: () => _showSuccessSnackBar('Saved to: $targetDir'),
      onError: (err) => _showErrorSnackBar('Receive failed: $err'),
    );

    try {
      await _connectionManager.authenticateAsServer(conn);
      await receiver.receiveFiles(
        conn, 
        downloadsDir.path, 
        onProgress: (p) => progressController.add(p),
        onConfirmManifest: (manifest) async {
          final chosen = await _showIncomingTransferDialog(manifest);
          if (chosen != null) {
            targetDir = chosen;
          }
          return chosen;
        },
        peerDeviceName: peerName,
      );
    } catch (e) {
      progressController.addError(e);
      debugPrint('Cloud receiving handshake failed: $e');
    } finally {
      await progressController.close();
      await conn.close();
      _loadTransferHistory();
    }
  }

  Future<void> _startReceiverTransfer(TlsConnection conn) async {
    final receiver = TransferManager(resumeStore: _resumeDb);
    final downloadsDir = await _getDestinationDirectory();
    final peerId = conn.peerDeviceId ?? 'unknown';
    final peerName = await _getDeviceNameForId(peerId);
    String targetDir = downloadsDir.path;
    final progressController = StreamController<TransferProgress>();

    _showProgressOverlay(
      title: 'Receiving File...',
      progressStream: progressController.stream,
      onComplete: () => _showSuccessSnackBar('Saved to: $targetDir'),
      onError: (err) => _showErrorSnackBar('Receive failed: $err'),
    );

    try {
      await receiver.receiveFiles(
        conn, 
        downloadsDir.path, 
        onProgress: (p) => progressController.add(p),
        onConfirmManifest: (manifest) async {
          final chosen = await _showIncomingTransferDialog(manifest);
          if (chosen != null) {
            targetDir = chosen;
          }
          return chosen;
        },
        peerDeviceName: peerName,
      );
    } catch (e) {
      progressController.addError(e);
      debugPrint('Error receiving file: $e');
    } finally {
      await progressController.close();
      await conn.close();
    }
  }

  // ── UI helpers ──

  void _showProgressOverlay({
    required String title,
    required Stream<TransferProgress> progressStream,
    required VoidCallback onComplete,
    required Function(String) onError,
  }) {
    bool isPopped = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StreamBuilder<TransferProgress>(
          stream: progressStream,
          builder: (buildCtx, snapshot) {
            if (snapshot.hasError) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!isPopped) {
                  isPopped = true;
                  Navigator.of(dialogCtx).pop();
                  onError(snapshot.error.toString());
                }
              });
              return const SizedBox.shrink();
            }
            if (!snapshot.hasData) {
              return AlertDialog(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                backgroundColor: _C.background,
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: _C.primary),
                    const SizedBox(height: 16),
                    Text('Preparing files...', style: _displayStyle(14, FontWeight.w600)),
                  ],
                ),
              );
            }
            final progress = snapshot.data!;
            final value = progress.fraction;
            if (value >= 1.0) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!isPopped) {
                  isPopped = true;
                  Navigator.of(dialogCtx).pop();
                  onComplete();
                }
              });
            }
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              backgroundColor: _C.background,
              title: Text(title, style: _displayStyle(16, FontWeight.w800)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: _C.secondaryBg.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _C.border),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: _C.primary.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            _isFileImage(progress.currentFileName) 
                                ? Icons.image_rounded 
                                : Icons.insert_drive_file_rounded, 
                            color: _C.primary, 
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                progress.currentFileName, 
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${_formatBytes(progress.transferredBytes)} of ${_formatBytes(progress.totalBytes)}',
                                style: TextStyle(color: _C.muted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: value.clamp(0.0, 1.0),
                      backgroundColor: _C.secondaryBg,
                      valueColor: const AlwaysStoppedAnimation(_C.primary),
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('${(value * 100).toStringAsFixed(1)}%', style: _displayStyle(20, FontWeight.w800)),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showSuccessSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle, color: _C.success), const SizedBox(width: 8), Text(msg),
      ]),
      backgroundColor: _C.ink,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ));
  }

  void _showErrorSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.error, color: _C.destructive), const SizedBox(width: 8), Expanded(child: Text(msg)),
      ]),
      backgroundColor: _C.ink,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ));
  }

  void _openQRScanner() {
    // macOS does not support mobile_scanner — show a paste-from-clipboard dialog instead
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      _openDesktopPairingDialog();
      return;
    }

    bool hasProcessed = false;
    final scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          backgroundColor: _C.background,
          appBar: AppBar(
            title: Text('Scan QR Code', style: _displayStyle(18, FontWeight.w700)),
            backgroundColor: _C.ink,
            foregroundColor: Colors.white,
            actions: [
              // Fallback: paste from clipboard
              IconButton(
                icon: const Icon(Icons.content_paste_rounded),
                tooltip: 'Paste pairing code',
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _openDesktopPairingDialog();
                },
              ),
            ],
          ),
          body: MobileScanner(
            controller: scannerController,
            errorBuilder: (context, error, child) {
              String message;
              switch (error.errorCode) {
                case MobileScannerErrorCode.permissionDenied:
                  message = 'Camera permission was denied.\nPlease go to Settings → Apps → Flashy → Permissions and enable Camera access.';
                  break;
                case MobileScannerErrorCode.unsupported:
                  message = 'Camera scanning is not supported on this device.';
                  break;
                default:
                  message = error.errorDetails?.message ?? 'Could not start the camera. Please check your camera permissions in Settings.';
              }
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.no_photography_outlined, size: 56, color: _C.destructive),
                      const SizedBox(height: 20),
                      const Text('Camera Unavailable', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 12),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _C.muted, fontSize: 14, height: 1.5),
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _openDesktopPairingDialog();
                          },
                          icon: const Icon(Icons.content_paste_rounded),
                          label: const Text('Paste Pairing Code Instead'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _C.primary,
                            foregroundColor: _C.ink,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
            onDetect: (capture) async {
              if (hasProcessed) return;
              final barcodes = capture.barcodes;
              if (barcodes.isNotEmpty && barcodes.first.rawValue != null) {
                final rawValue = barcodes.first.rawValue!;
                if (rawValue.startsWith('flashy-pair:')) {
                  final parts = rawValue.split(':');
                  if (parts.length >= 4) {
                    hasProcessed = true;
                    final peerId = parts[1];
                    final peerKey = parts[2];
                    final peerName = parts[3];
                    await _contactsDb.addContact(deviceId: peerId, deviceName: peerName, publicKey: peerKey);
                    _pairedDeviceIds.add(peerId);
                    scannerController.stop();
                    if (mounted) {
                      Navigator.of(ctx).pop();
                      _showSuccessSnackBar('Paired with $peerName!');
                      setState(() {});
                    }
                  }
                }
              }
            },
          ),
        ),
      ),
    ).then((_) {
      scannerController.dispose();
    });
  }

  String _formatDateTime(String? isoString) {
    if (isoString == null) return '';
    try {
      final dt = DateTime.parse(isoString).toLocal();
      final month = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][dt.month - 1];
      final min = dt.minute.toString().padLeft(2, '0');
      final hour = dt.hour.toString().padLeft(2, '0');
      return '$hour:$min · $month ${dt.day}';
    } catch (_) {
      return '';
    }
  }

  Future<void> _loadTransferHistory() async {
    final history = await _resumeDb.getTransferHistory();
    final sentToday = await _resumeDb.getTodayTransferCount('send');
    final totalReceived = history.where((item) => item['direction'] == 'receive' && item['status'] == 'completed').length;
    if (mounted) {
      setState(() {
        _transferHistory = history;
        _sentTodayCount = sentToday;
        _receivedCount = totalReceived;
      });
    }
  }

  Widget _filterTab(String key, String label) {
    final isSelected = _historyFilter == key;
    return GestureDetector(
      onTap: () {
        setState(() {
          _historyFilter = key;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? _C.primary : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? _C.primary : Colors.white.withOpacity(0.1)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? _C.ink : Colors.white,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildTransferHistorySection() {
    if (_transferHistory.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _C.card,
          borderRadius: BorderRadius.circular(32),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 24, offset: const Offset(0, 8))],
        ),
        child: Column(
          children: [
            const Icon(Icons.history_rounded, color: Colors.white24, size: 36),
            const SizedBox(height: 12),
            Text('No transfer history yet', style: TextStyle(color: _C.muted, fontSize: 13)),
          ],
        ),
      );
    }

    final filteredHistory = _transferHistory.where((item) {
      if (_historyFilter == 'all') return true;
      return item['direction'] == _historyFilter;
    }).toList();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(32),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Transfer History', style: _displayStyle(16, FontWeight.w700)),
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined, size: 20, color: _C.destructive),
                tooltip: 'Clear history',
                onPressed: () async {
                  for (final item in _transferHistory) {
                    await _resumeDb.deleteTransferState(item['transfer_id'] as String);
                  }
                  await _loadTransferHistory();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Filter Tabs
          Row(
            children: [
              _filterTab('all', 'All'),
              const SizedBox(width: 8),
              _filterTab('send', 'Sent'),
              const SizedBox(width: 8),
              _filterTab('receive', 'Received'),
            ],
          ),
          const SizedBox(height: 16),
          filteredHistory.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24.0),
                  child: Center(
                    child: Text(
                      'No items in this category',
                      style: TextStyle(color: _C.muted, fontSize: 12),
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: filteredHistory.length,
                  separatorBuilder: (_, __) => const Divider(height: 24, color: Colors.white10),
                  itemBuilder: (context, index) {
                    final item = filteredHistory[index];
                    final isSend = item['direction'] == 'send';
                    final isSuccess = item['status'] == 'completed';
                    final peerName = item['peer_device_name'] as String? ?? 'Unknown Device';
                    final savePath = item['save_path'] as String?;
                    final createdAt = item['created_at'] as String?;
                    final timeStr = _formatDateTime(createdAt);
                    
                    TransferManifest manifest;
                    try {
                      manifest = TransferManifest.fromJson(jsonDecode(item['manifest_json'] as String));
                    } catch (_) {
                      return const SizedBox.shrink();
                    }
                    
                    final fileName = manifest.files.isNotEmpty ? manifest.files.first.relativePath : 'Unknown file';
                    final totalSize = _formatBytes(manifest.totalBytes);
                    
                    return InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () async {
                        if (!isSend && isSuccess && savePath != null) {
                          final filePath = p.join(savePath, fileName);
                          final file = File(filePath);
                          if (await file.exists()) {
                            try {
                              await OpenFilex.open(filePath);
                            } catch (e) {
                              _showErrorSnackBar('Could not open file: $e');
                            }
                          } else {
                            _showErrorSnackBar('File no longer exists at: $filePath');
                          }
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isSuccess 
                                    ? (isSend ? _C.primary.withOpacity(0.15) : _C.success.withOpacity(0.15))
                                    : _C.destructive.withOpacity(0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isSuccess 
                                    ? (isSend ? Icons.call_made_rounded : Icons.call_received_rounded)
                                    : Icons.error_outline_rounded,
                                color: isSuccess 
                                    ? (isSend ? _C.primary : _C.success)
                                    : _C.destructive,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    fileName,
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    isSend ? 'Sent to: $peerName' : 'Received from: $peerName',
                                    style: TextStyle(color: _C.muted.withOpacity(0.8), fontSize: 11),
                                  ),
                                  if (!isSend && isSuccess && savePath != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      'Saved to: ...${savePath.length > 25 ? savePath.substring(savePath.length - 25) : savePath}',
                                      style: TextStyle(color: _C.muted.withOpacity(0.6), fontSize: 10, fontStyle: FontStyle.italic),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Text(
                                        totalSize,
                                        style: TextStyle(color: _C.muted, fontSize: 11),
                                      ),
                                      if (timeStr.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        const Icon(Icons.circle, size: 4, color: Colors.white24),
                                        const SizedBox(width: 6),
                                        Text(
                                          timeStr,
                                          style: TextStyle(color: _C.muted, fontSize: 11),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  isSuccess ? 'Success' : 'Failed',
                                  style: TextStyle(
                                    color: isSuccess ? _C.success : _C.destructive,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11,
                                  ),
                                ),
                                if (!isSend && isSuccess && savePath != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8.0),
                                    child: Icon(Icons.open_in_new_rounded, size: 14, color: _C.primary.withOpacity(0.7)),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ],
      ),
    );
  }

  /// Desktop/fallback pairing dialog — paste a pairing code from clipboard
  void _openDesktopPairingDialog() {
    final pasteController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: _C.background,
          title: Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: _C.primary.withOpacity(0.2), shape: BoxShape.circle),
              child: const Icon(Icons.link_rounded, color: _C.primary),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Text('Pair Device', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18))),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Copy the pairing code from the other device\'s Pair & QR tab, then paste it below:',
                style: TextStyle(color: _C.muted, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pasteController,
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: 'flashy-pair:xxxxxxxx:...',
                  hintStyle: TextStyle(color: _C.muted.withOpacity(0.5), fontSize: 12, fontFamily: 'monospace'),
                  filled: true,
                  fillColor: _C.secondaryBg.withOpacity(0.3),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: _C.border)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _C.primary, width: 1.5)),
                  contentPadding: const EdgeInsets.all(16),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste_go_rounded),
                    tooltip: 'Paste from clipboard',
                    onPressed: () async {
                      final data = await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null) {
                        pasteController.text = data!.text!;
                      }
                    },
                  ),
                ),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Cancel', style: TextStyle(color: _C.muted, fontWeight: FontWeight.w600)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final val = pasteController.text.trim();
                if (val.startsWith('flashy-pair:')) {
                  final parts = val.split(':');
                  if (parts.length >= 4) {
                    final peerId = parts[1];
                    final peerKey = parts[2];
                    final peerName = parts[3];
                    await _contactsDb.addContact(deviceId: peerId, deviceName: peerName, publicKey: peerKey);
                    _pairedDeviceIds.add(peerId);
                    if (mounted) {
                      Navigator.of(ctx).pop();
                      _showSuccessSnackBar('Paired with $peerName!');
                      setState(() {});
                    }
                  } else {
                    _showErrorSnackBar('Invalid pairing code format');
                  }
                } else {
                  _showErrorSnackBar('Code must start with flashy-pair:');
                }
              },
              icon: const Icon(Icons.handshake_rounded, size: 18),
              label: const Text('Pair'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _C.primary,
                foregroundColor: _C.ink,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
            ),
          ],
        );
      },
    ).then((_) => pasteController.dispose());
  }

  // ═══════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    if (_initError.isNotEmpty) return _buildErrorScreen();
    if (!_initialized) return _buildLoadingScreen();

    final isDesktop = MediaQuery.of(context).size.width >= 1024;

    // Deezer-style login screen on launch
    if (!isDesktop && !_sessionStore.isLoggedIn && !_skippedLogin && !_firebaseAuth.isSignedIn) {
      return _buildDeezerLoginScreen();
    }

    return Scaffold(
      backgroundColor: _C.background,
      body: Stack(
        children: [
          // Background gradient blobs
          ..._buildBackgroundBlobs(),
          // Main content
          if (isDesktop) _buildDesktopLayout() else _buildMobileLayout(),
          // Account modal
          if (_accountOpen) _buildAccountModal(),
        ],
      ),
    );
  }

  List<Widget> _buildBackgroundBlobs() {
    return [
      Positioned(top: -80, left: -40, child: Container(
        width: 300, height: 250,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [_C.primary.withOpacity(0.18), Colors.transparent]),
        ),
      )),
      Positioned(top: -60, right: -30, child: Container(
        width: 280, height: 240,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [_C.primaryGlow.withOpacity(0.22), Colors.transparent]),
        ),
      )),
      Positioned(bottom: -100, left: 80, right: 80, child: Container(
        height: 260,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [_C.primary.withOpacity(0.12), Colors.transparent]),
        ),
      )),
    ];
  }

  Widget _buildErrorScreen() {
    return Scaffold(
      backgroundColor: _C.background,
      body: Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 64, color: _C.destructive),
          const SizedBox(height: 16),
          Text('Initialization Error', style: _displayStyle(22, FontWeight.w700)),
          const SizedBox(height: 8),
          Text(_initError, textAlign: TextAlign.center, style: const TextStyle(color: _C.muted)),
          const SizedBox(height: 24),
          _primaryButton('Retry', onPressed: _initializeServices),
        ]),
      )),
    );
  }

  Widget _buildLoadingScreen() {
    return Scaffold(
      backgroundColor: _C.background,
      body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 48, height: 48, child: CircularProgressIndicator(color: _C.primary, strokeWidth: 3)),
        const SizedBox(height: 24),
        Text('Initializing Flashy engine...', style: TextStyle(color: _C.muted)),
      ])),
    );
  }

  // ═══════════════════════════════════════════════════════
  // DESKTOP LAYOUT (3-column)
  // ═══════════════════════════════════════════════════════

  Widget _buildDesktopLayout() {
    return Row(children: [
      // Left sidebar
      _buildDesktopSidebar(),
      // Center main
      Expanded(child: _buildDesktopMain()),
      // Right panel
      _buildDesktopRightPanel(),
    ]);
  }

  Widget _buildDesktopSidebar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 244,
        child: Container(
          decoration: BoxDecoration(
            color: _C.ink,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: const Color(0x66406040), width: 1),
            boxShadow: [BoxShadow(color: _C.ink.withOpacity(0.3), blurRadius: 40, offset: const Offset(0, 16))],
          ),
          child: Column(children: [
            // Logo
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(color: _C.primary, borderRadius: BorderRadius.circular(12)),
                  child: Center(child: Text('F', style: _displayStyle(16, FontWeight.w900, color: _C.ink))),
                ),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Flashy', style: _displayStyle(16, FontWeight.w700, color: Colors.white)),
                  Text('DESKTOP', style: TextStyle(fontSize: 10, color: Colors.white60, letterSpacing: 2, fontWeight: FontWeight.w600)),
                ]),
              ]),
            ),
            // Avatar / profile button
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: GestureDetector(
                onTap: () => setState(() => _accountOpen = true),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(16)),
                  child: Row(children: [
                    _avatarCircle(40),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_identity.identity.deviceName, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                      Text(_sessionStore.isLoggedIn ? 'Pro' : 'Free', style: TextStyle(fontSize: 10, color: _C.primary, fontWeight: FontWeight.w700, letterSpacing: 1)),
                    ])),
                  ]),
                ),
              ),
            ),
            // Nav items
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 24, 12, 0),
              child: Column(children: [
                _sidebarNavItem(Icons.home_rounded, 'Home', 'home'),
                _sidebarNavItem(Icons.send_rounded, 'Send files', 'send'),
                _sidebarNavItem(Icons.qr_code_2_rounded, 'Pair & QR', 'qr'),
                _sidebarNavItem(Icons.devices_rounded, 'Devices', 'devices'),
                _sidebarNavItem(Icons.settings_rounded, 'Settings', 'settings', onTap: () => setState(() => _accountOpen = true)),
              ]),
            ),
            const Spacer(),
            // WiFi status
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(16)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.wifi, size: 14, color: _C.primary),
                    const SizedBox(width: 8),
                    StreamBuilder<List<LanDevice>>(
                      stream: _discovery.discoveredDevices,
                      builder: (ctx, snap) => Text(
                        'Local Network',
                        style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  StreamBuilder<List<LanDevice>>(
                    stream: _discovery.discoveredDevices,
                    builder: (ctx, snap) {
                      final count = snap.data?.length ?? 0;
                      return Text('$count peer${count != 1 ? 's' : ''} reachable on this LAN', style: TextStyle(fontSize: 10, color: Colors.white60));
                    },
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _sidebarNavItem(IconData icon, String label, String tabId, {VoidCallback? onTap}) {
    final active = _tab == tabId && onTap == null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap ?? () => setState(() => _tab = tabId),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: active ? _C.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(icon, size: 18, color: active ? _C.ink : Colors.white70),
              const SizedBox(width: 12),
              Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: active ? _C.ink : Colors.white70)),
            ]),
          ),
        ),
      ),
    );
  }

  // ── Desktop Center Main ──

  Widget _buildDesktopMain() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(children: [
              _buildHeroCard(large: true),
              const SizedBox(height: 16),
              _buildActionCircles(),
              const SizedBox(height: 16),
              _buildTransfersList(),
              const SizedBox(height: 16),
              _buildTransferHistorySection(),
            ]),
          ),
        ),
      ),
    );
  }

  // ── Desktop Right Panel ──

  Widget _buildDesktopRightPanel() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: 340,
        child: Container(
          decoration: BoxDecoration(
            color: _C.card,
            borderRadius: BorderRadius.circular(32),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 32, offset: const Offset(0, 8))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(
                    _tab == 'qr' ? 'Pair via QR'
                      : _tab == 'send' ? 'Send files'
                      : _tab == 'devices' ? 'Your devices'
                      : 'Quick actions',
                    style: _displayStyle(16, FontWeight.w700),
                  ),
                  if (_tab != 'home')
                    _iconBtn(Icons.close, onTap: () => setState(() => _tab = 'home')),
                ]),
                const SizedBox(height: 16),
                if (_tab == 'qr') _buildQrPanel()
                else if (_tab == 'send') _buildSendPanel()
                else if (_tab == 'devices') _buildDevicesPanel()
                else _buildQuickActions(),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  // MOBILE LAYOUT
  // ═══════════════════════════════════════════════════════

  Widget _buildMobileLayout() {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Stack(children: [
      // Main home content
      Positioned.fill(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: 90 + bottomPadding),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Column(children: [
                _buildHeroCard(large: false),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildActionCircles(),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildTransfersList(),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildTransferHistorySection(),
                ),
              ]),
            ),
          ),
        ),
      ),
      // Bottom nav
      _buildMobileBottomNav(bottomPadding),
      // Fullscreen overlays
      if (_tab == 'send') _buildFullscreenSheet('Send files', _buildSendPanel()),
      if (_tab == 'qr') _buildFullscreenSheet('Pair via QR', _buildQrPanel()),
      if (_tab == 'devices') _buildFullscreenSheet('Your devices', _buildDevicesPanel()),
    ]);
  }

  Widget _buildMobileBottomNav(double bottomPadding) {
    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(40, 10, 40, 10 + bottomPadding),
        decoration: BoxDecoration(
          color: _C.ink,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: const Border(top: BorderSide(color: Color(0x33406040), width: 1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 16,
              offset: const Offset(0, -4),
            )
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _mobileNavBtn(Icons.home_rounded, 'home'),
            // Centered Send button (slightly smaller, not sticking out as much)
            GestureDetector(
              onTap: () => setState(() => _tab = 'send'),
              child: Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: _C.primary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _C.primary.withOpacity(0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    )
                  ],
                ),
                child: const Icon(Icons.send_rounded, color: _C.ink, size: 20),
              ),
            ),
            _mobileNavBtn(Icons.qr_code_2_rounded, 'qr'),
          ],
        ),
      ),
    );
  }

  Widget _mobileNavBtn(IconData icon, String tabId) {
    final active = _tab == tabId;
    return GestureDetector(
      onTap: () => setState(() => _tab = tabId),
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: active ? _C.primary.withOpacity(0.15) : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 22,
          color: active ? _C.primary : Colors.white70,
        ),
      ),
    );
  }

  Widget _buildFullscreenSheet(String title, Widget content) {
    final topPadding = MediaQuery.of(context).padding.top;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Positioned.fill(
      child: Material(
        color: _C.background,
        child: Column(children: [
          // Header
          Container(
            padding: EdgeInsets.fromLTRB(20, 16 + topPadding, 20, 16),
            decoration: BoxDecoration(
              color: _C.ink,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
            ),
            child: Row(children: [
              _iconBtn(Icons.arrow_back, color: _C.primary, bgColor: _C.primary.withOpacity(0.2),
                onTap: () => setState(() => _tab = 'home')),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: _displayStyle(18, FontWeight.w700, color: Colors.white))),
              _iconBtn(Icons.close, color: Colors.white, bgColor: Colors.white.withOpacity(0.1),
                onTap: () => setState(() => _tab = 'home')),
            ]),
          ),
          Expanded(child: SingleChildScrollView(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomPadding), child: content)),
        ]),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  // SHARED COMPONENTS
  // ═══════════════════════════════════════════════════════

  Widget _buildHeroCard({required bool large}) {
    final topPadding = large ? 0.0 : MediaQuery.of(context).padding.top;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(20, (large ? 32 : 20) + topPadding, 20, 20),
      decoration: BoxDecoration(
        color: _C.ink,
        borderRadius: large
            ? BorderRadius.circular(32)
            : const BorderRadius.vertical(bottom: Radius.circular(32)),
        border: large
            ? Border.all(color: const Color(0x66406040))
            : const Border(bottom: BorderSide(color: Color(0x66406040))),
        boxShadow: [
          BoxShadow(
            color: _C.ink.withOpacity(0.35),
            blurRadius: large ? 50 : 30,
            offset: Offset(0, large ? 18 : 10),
          )
        ],
      ),
      child: Stack(children: [
        // Glow blob
        Positioned(top: -40, right: -30, child: Container(
          width: 200, height: 200,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [_C.primary.withOpacity(0.15), Colors.transparent]),
          ),
        )),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header row
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            large
              ? _avatarCircle(44)
              : Row(children: [
                  GestureDetector(
                    onTap: () => setState(() => _accountOpen = true),
                    child: _avatarCircle(44),
                  ),
                ]),
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: _C.primary.withOpacity(0.2), shape: BoxShape.circle,
                border: Border.all(color: _C.primary.withOpacity(0.4)),
              ),
              child: Icon(Icons.notifications_outlined, size: 18, color: _C.primary),
            ),
          ]),
          SizedBox(height: large ? 16 : 12),
          Text('FLASHY NETWORK', style: TextStyle(fontSize: 10, color: _C.primary, fontWeight: FontWeight.w700, letterSpacing: 3)),
          const SizedBox(height: 8),
          Text.rich(TextSpan(children: [
            TextSpan(text: 'Welcome back, \n', style: _displayStyle(large ? 32 : 24, FontWeight.w600, color: Colors.white)),
            TextSpan(
              text: _sessionStore.isLoggedIn && _sessionStore.userName != null && _sessionStore.userName!.isNotEmpty
                ? _sessionStore.userName
                : _identity.identity.deviceName.split(' ').first,
              style: _displayStyle(large ? 44 : 36, FontWeight.w800, color: _C.primary),
            ),
          ])),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.verified_user, size: 14, color: _C.primary),
            const SizedBox(width: 6),
            Expanded(
              child: StreamBuilder<List<LanDevice>>(
                stream: _discovery.discoveredDevices,
                builder: (ctx, snap) {
                  final count = snap.data?.length ?? 0;
                  return Text(
                    'End-to-end encrypted · $count device${count != 1 ? 's' : ''} live on your LAN',
                    style: TextStyle(fontSize: large ? 14 : 11, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  );
                },
              ),
            ),
          ]),
          const SizedBox(height: 24),
          // Stat tiles
          Row(children: [
            Expanded(child: _statTile('SENT TODAY', '$_sentTodayCount')),
            const SizedBox(width: 12),
            Expanded(child: _statTile('RECEIVED', '$_receivedCount')),
          ]),
        ]),
      ]),
    );
  }

  Widget _statTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 10, color: Colors.white60, fontWeight: FontWeight.w700, letterSpacing: 1)),
        const SizedBox(height: 4),
        Text(value, style: _displayStyle(20, FontWeight.w700, color: Colors.white)),
      ]),
    );
  }

  Widget _buildActionCircles() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(32),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Row(children: [
        Expanded(child: _actionCircle('Receive', Icons.download_rounded, isSuccess: true, active: _filter == 'in',
          onTap: () => setState(() {
            _filter = 'in';
            _tab = 'home';
          }))),
        const SizedBox(width: 12),
        Expanded(child: _actionCircle('Send', Icons.upload_rounded, isSuccess: false, active: _filter == 'out',
          onTap: () => setState(() {
            _filter = 'out';
            _tab = 'send';
          }))),
      ]),
    );
  }

  Widget _actionCircle(String label, IconData icon, {bool isSuccess = false, bool active = false, VoidCallback? onTap}) {
    final activeColor = isSuccess ? _C.success : _C.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? _C.secondaryBg.withOpacity(0.7) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: active ? activeColor : _C.card,
              shape: BoxShape.circle,
              border: active ? null : Border.all(color: activeColor.withOpacity(0.4), width: 2),
              boxShadow: active
                ? [BoxShadow(color: activeColor.withOpacity(0.4), blurRadius: 16)]
                : null,
            ),
            child: Icon(icon, size: 20, color: active ? (isSuccess ? Colors.white : _C.ink) : activeColor),
          ),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _C.foreground)),
        ]),
      ),
    );
  }

  Widget _buildTransfersList() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(32),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Send to local devices', style: _displayStyle(16, FontWeight.w700)),
        const SizedBox(height: 12),
        // Show discovered devices as transfer targets
        StreamBuilder<List<LanDevice>>(
          stream: _discovery.discoveredDevices,
          builder: (ctx, snap) {
            if (!snap.hasData || snap.data!.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Column(children: [
                  const _GlowPulseOrb(),
                  const SizedBox(height: 16),
                  Text('Scanning local Wi-Fi for peers...', style: TextStyle(color: _C.muted, fontSize: 13)),
                ])),
              );
            }
            final devices = snap.data!;
            return Column(children: devices.map((d) => _transferDeviceRow(d)).toList());
          },
        ),
        // Cloud devices
        if (_sessionStore.isLoggedIn && _cloudDevices.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Cloud linked', style: TextStyle(fontSize: 11, color: _C.muted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ..._cloudDevices.map((d) => _cloudDeviceRow(d)),
        ],
      ]),
    );
  }

  Widget _transferDeviceRow(LanDevice device) {
    return InkWell(
      onTap: () {
        _startSenderTransfer(device, filePath: _selectedFilePath);
        if (_selectedFilePath != null) {
          setState(() {
            _selectedFilePath = null;
          });
        }
      },
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: _C.primary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              device.deviceId.hashCode.isEven ? Icons.phone_android_rounded : Icons.laptop_rounded,
              color: _C.ink, size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(device.deviceName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            Row(children: [
              Icon(Icons.laptop_rounded, size: 12, color: _C.muted),
              const SizedBox(width: 4),
              Text(device.ipAddress, style: TextStyle(fontSize: 11, color: _C.muted)),
            ]),
          ])),
          Text('Send', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _C.primary)),
        ]),
      ),
    );
  }

  Widget _cloudDeviceRow(Map<String, dynamic> device) {
    final isOnline = device['isOnline'] as bool? ?? false;
    return InkWell(
      onTap: isOnline ? () {
        _startCloudSenderTransfer(device['id'] as String, device['device_name'] as String, filePath: _selectedFilePath);
        if (_selectedFilePath != null) {
          setState(() {
            _selectedFilePath = null;
          });
        }
      } : null,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: isOnline ? _C.success.withOpacity(0.15) : _C.secondaryBg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(Icons.cloud_rounded, color: isOnline ? _C.success : _C.muted, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(device['device_name'] as String, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            Text(isOnline ? 'Online (Cloud)' : 'Offline', style: TextStyle(fontSize: 11, color: isOnline ? _C.success : _C.muted)),
          ])),
          if (isOnline) Text('Send', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _C.primary)),
        ]),
      ),
    );
  }

  // ── Quick Actions (Desktop right panel default) ──

  Widget _buildQuickActions() {
    return Column(children: [
      _quickActionBtn(Icons.send_rounded, 'Send files', 'Pick a paired device', _C.primary, () => setState(() => _tab = 'send')),
      const SizedBox(height: 8),
      _quickActionBtn(Icons.qr_code_2_rounded, 'Pair a new device', 'Show your QR or scan', _C.ink, () => setState(() => _tab = 'qr'), iconColor: _C.primary),
      const SizedBox(height: 24),
      Align(alignment: Alignment.centerLeft, child: Text('Linked devices', style: _displayStyle(14, FontWeight.w700))),
      const SizedBox(height: 12),
      // Paired contacts
      FutureBuilder<List<Map<String, dynamic>>>(
        future: _contactsDb.getContacts(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return _emptyCard('No paired devices yet');
          }
          return Column(children: snapshot.data!.map((c) => _linkedDeviceRow(
            c['device_name'] as String,
            'Paired device',
            (c['device_id'] as String).substring(0, 8),
            true,
          )).toList());
        },
      ),
      // Cloud devices
      ..._cloudDevices.map((d) => _linkedDeviceRow(
        d['device_name'] as String,
        'Cloud linked',
        (d['id'] as String).substring(0, 8),
        d['isOnline'] as bool? ?? false,
      )),
    ]);
  }

  Widget _quickActionBtn(IconData icon, String title, String subtitle, Color iconBg, VoidCallback onTap, {Color? iconColor}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: iconBg == _C.primary ? _C.primary.withOpacity(0.15) : _C.secondaryBg.withOpacity(0.6),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 18, color: iconColor ?? _C.ink),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            Text(subtitle, style: TextStyle(fontSize: 11, color: _C.muted)),
          ]),
        ]),
      ),
    );
  }

  Widget _linkedDeviceRow(String name, String platform, String idPrefix, bool online) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: _C.secondaryBg.withOpacity(0.4), borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(color: _C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: _C.border)),
          child: Icon(Icons.devices_rounded, size: 16, color: _C.ink),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
          Text(platform, style: TextStyle(fontSize: 10, color: _C.muted)),
        ])),
        Container(width: 8, height: 8, decoration: BoxDecoration(
          shape: BoxShape.circle, color: online ? _C.success : _C.muted,
        )),
      ]),
    );
  }

  // ── Send Panel ──

  Widget _buildSendPanel() {
    final hasSelected = _selectedFilePath != null;
    final fileName = hasSelected ? _selectedFilePath!.split(Platform.pathSeparator).last : '';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Drop zone
      GestureDetector(
        onTap: () async {
          final result = await FilePicker.platform.pickFiles();
          if (result != null && result.files.single.path != null) {
            setState(() {
              _selectedFilePath = result.files.single.path;
            });
            _showSuccessSnackBar('File selected: ${result.files.single.name}');
          }
        },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: hasSelected ? _C.success.withOpacity(0.6) : _C.primary.withOpacity(0.5), width: 2, strokeAlign: BorderSide.strokeAlignOutside),
            color: hasSelected ? _C.success.withOpacity(0.05) : _C.primary.withOpacity(0.05),
          ),
          child: hasSelected
              ? Row(children: [
                  Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(color: _C.success, borderRadius: BorderRadius.circular(16)),
                    child: const Icon(Icons.file_present_rounded, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(fileName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      const Text('Ready to beam • Choose a destination below', style: TextStyle(fontSize: 11, color: _C.muted)),
                    ]),
                  ),
                  _iconBtn(Icons.close, color: _C.destructive, bgColor: _C.destructive.withOpacity(0.1), onTap: () {
                    setState(() {
                      _selectedFilePath = null;
                    });
                  }),
                ])
              : Column(children: [
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(color: _C.primary, borderRadius: BorderRadius.circular(16)),
                    child: const Icon(Icons.add, color: _C.ink, size: 24),
                  ),
                  const SizedBox(height: 12),
                  const Text('Drop files or click to pick', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  const Text('End-to-end encrypted · Up to 5 GB per beam', style: TextStyle(fontSize: 11, color: _C.muted)),
                ]),
        ),
      ),
      const SizedBox(height: 24),
      Text('Pick a destination', style: _displayStyle(14, FontWeight.w700)),
      const SizedBox(height: 12),
      // LAN devices
      StreamBuilder<List<LanDevice>>(
        stream: _discovery.discoveredDevices,
        builder: (ctx, snap) {
          if (!snap.hasData || snap.data!.isEmpty) {
            return _emptyCard('No devices found on local network');
          }
          return Column(children: snap.data!.map((d) => _destinationRow(d)).toList());
        },
      ),
      // Cloud devices
      ..._cloudDevices.where((d) => d['isOnline'] == true).map((d) => _cloudDestinationRow(d)),
    ]);
  }

  Future<bool> _showPairingDialog(String deviceName, String deviceId) async {
    final completer = Completer<bool>();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: _C.background,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: _C.primary.withOpacity(0.2), shape: BoxShape.circle),
                child: const Icon(Icons.wifi_tethering_rounded, color: _C.primary),
              ),
              const SizedBox(width: 12),
              const Text('Pairing Request', style: TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A local device wants to pair with you:',
                style: TextStyle(color: _C.muted, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _C.secondaryBg.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _C.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(deviceName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text(
                      'ID: ${deviceId.substring(0, 8)}...',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: _C.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Only accept this request if you recognize this device on your local Wi-Fi network.',
                style: TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                completer.complete(false);
              },
              child: Text('Decline', style: TextStyle(color: _C.destructive, fontWeight: FontWeight.w600)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                completer.complete(true);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _C.primary,
                foregroundColor: _C.ink,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                elevation: 0,
              ),
              child: const Text('Accept & Pair', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        );
      },
    );
    return completer.future;
  }

  Future<void> _initiateLocalPairing(LanDevice device) async {
    _showSuccessSnackBar('Sending pairing request to ${device.deviceName}...');
    try {
      await _connectionManager.requestLocalPairing(
        ipAddress: device.ipAddress,
        port: device.port,
        onPairCompleted: (id, name, key) async {
          await _contactsDb.addContact(deviceId: id, deviceName: name, publicKey: key);
          _pairedDeviceIds.add(id);
          _showSuccessSnackBar('Mutually paired with $name!');
          setState(() {});
        },
      );
    } catch (e) {
      _showErrorSnackBar('Pairing failed: ${e.toString().replaceAll('HttpException: ', '')}');
    }
  }

  Widget _destinationRow(LanDevice device) {
    final isPaired = _pairedDeviceIds.contains(device.deviceId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _C.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: isPaired
                ? () {
                    _startSenderTransfer(device, filePath: _selectedFilePath);
                    if (_selectedFilePath != null) {
                      setState(() {
                        _selectedFilePath = null;
                      });
                    }
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: isPaired ? _C.primary.withOpacity(0.2) : _C.secondaryBg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    device.deviceId.hashCode.isEven ? Icons.phone_android_rounded : Icons.laptop_rounded,
                    size: 20,
                    color: isPaired ? _C.ink : _C.muted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(device.deviceName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                  Text(isPaired ? device.ipAddress : 'Tap "Pair" to link locally', style: TextStyle(fontSize: 12, color: _C.muted)),
                ])),
                if (isPaired)
                  Icon(Icons.chevron_right, size: 18, color: _C.muted)
                else
                  ElevatedButton(
                    onPressed: () => _initiateLocalPairing(device),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _C.primary,
                      foregroundColor: _C.ink,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                    ),
                    child: const Text('Pair', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cloudDestinationRow(Map<String, dynamic> device) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () {
          _startCloudSenderTransfer(device['id'] as String, device['device_name'] as String, filePath: _selectedFilePath);
          if (_selectedFilePath != null) {
            setState(() {
              _selectedFilePath = null;
            });
          }
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.border)),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(color: _C.success.withOpacity(0.2), borderRadius: BorderRadius.circular(16)),
              child: Icon(Icons.cloud_rounded, size: 20, color: _C.success),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(device['device_name'] as String, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text('Cloud relay', style: TextStyle(fontSize: 12, color: _C.muted)),
            ])),
            Icon(Icons.chevron_right, size: 18, color: _C.muted),
          ]),
        ),
      ),
    );
  }

  // ── QR Panel ──

  Widget _buildQrPanel() {
    final pairingString = 'flashy-pair:${_identity.identity.deviceId}:${_identity.publicKeyHex}:${_identity.identity.deviceName}';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: _C.secondaryBg.withOpacity(0.4), borderRadius: BorderRadius.circular(24)),
      child: Column(children: [
        Text('THIS DEVICE', style: TextStyle(fontSize: 11, color: _C.muted, letterSpacing: 2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(_identity.identity.deviceName, style: _displayStyle(18, FontWeight.w700)),
        Text(
          '${_identity.identity.deviceId.substring(0, 8)} · ed25519',
          style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: _C.muted),
        ),
        const SizedBox(height: 16),
        // QR code
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _C.foreground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _C.primary.withOpacity(0.4), width: 2),
            boxShadow: [BoxShadow(color: _C.primary.withOpacity(0.3), blurRadius: 40)],
          ),
          child: QrImageView(
            data: pairingString,
            version: QrVersions.auto,
            size: 200,
            gapless: false,
            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: _C.background),
            dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: _C.background),
          ),
        ),
        const SizedBox(height: 12),
        // Copy button
        InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: pairingString));
            _showSuccessSnackBar('Pairing code copied to clipboard!');
          },
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.85),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _C.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.copy, size: 14, color: _C.muted),
              const SizedBox(width: 8),
              Text(
                'flashy-pair:${_identity.identity.deviceId.substring(0, 8)}:...',
                style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: _C.muted),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        // Scan button
        SizedBox(
          width: double.infinity,
          child: _primaryButton('Scan another device', icon: Icons.qr_code_scanner_rounded, onPressed: _openQRScanner),
        ),
        const SizedBox(height: 24),
        const Divider(color: _C.border),
        const SizedBox(height: 12),
        Text('MANUAL PAIRING (FALLBACK)', style: TextStyle(fontSize: 11, color: _C.muted, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _manualPairController,
              decoration: InputDecoration(
                hintText: 'Paste flashy-pair: code here',
                filled: true,
                fillColor: Colors.white.withOpacity(0.9),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _C.border)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _C.primary, width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
          const SizedBox(width: 8),
          _iconBtn(Icons.arrow_forward_rounded, color: _C.ink, bgColor: _C.primary, onTap: () async {
            final val = _manualPairController.text.trim();
            if (val.startsWith('flashy-pair:')) {
              final parts = val.split(':');
              if (parts.length >= 4) {
                final peerId = parts[1];
                final peerKey = parts[2];
                final peerName = parts[3];
                await _contactsDb.addContact(deviceId: peerId, deviceName: peerName, publicKey: peerKey);
                _pairedDeviceIds.add(peerId);
                _showSuccessSnackBar('Manually paired with $peerName!');
                _manualPairController.clear();
                setState(() {});
              } else {
                _showErrorSnackBar('Invalid pairing code format');
              }
            } else {
              _showErrorSnackBar('Please paste a valid flashy-pair: code');
            }
          }),
        ]),
      ]),
    );
  }

  // ── Devices Panel ──

  Widget _buildDevicesPanel() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FutureBuilder<List<Map<String, dynamic>>>(
        future: _contactsDb.getContacts(),
        builder: (context, snapshot) {
          final contacts = snapshot.data ?? [];
          final onlineCount = _cloudDevices.where((d) => d['isOnline'] == true).length + contacts.length;
          final totalCount = contacts.length + _cloudDevices.length;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$onlineCount live · $totalCount linked to your account', style: TextStyle(fontSize: 11, color: _C.muted)),
            const SizedBox(height: 12),
            ...contacts.map((c) => _devicePanelRow(
              c['device_name'] as String,
              'Paired locally',
              (c['device_id'] as String).substring(0, 8),
              true,
            )),
            ..._cloudDevices.map((d) => _devicePanelRow(
              d['device_name'] as String,
              'Cloud linked',
              (d['id'] as String).substring(0, 8),
              d['isOnline'] as bool? ?? false,
            )),
            if (contacts.isEmpty && _cloudDevices.isEmpty) _emptyCard('No linked devices yet'),
          ]);
        },
      ),
    ]);
  }

  Widget _devicePanelRow(String name, String platform, String id, bool online) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: _C.secondaryBg.withOpacity(0.6), borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Stack(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: _C.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: _C.border)),
            child: Icon(Icons.devices_rounded, size: 16, color: _C.ink),
          ),
          Positioned(bottom: -2, right: -2, child: Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle, color: online ? _C.success : _C.muted,
              border: Border.all(color: _C.card, width: 2),
            ),
          )),
        ]),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
          Text(platform, style: TextStyle(fontSize: 11, color: _C.muted)),
          Text(id, style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: _C.muted.withOpacity(0.8))),
        ])),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: online ? _C.success.withOpacity(0.2) : _C.secondaryBg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            online ? 'LIVE' : 'IDLE',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: online ? _C.success : _C.muted),
          ),
        ),
      ]),
    );
  }

  // ── Account Modal ──

  Widget _buildAccountModal() {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    return Positioned.fill(
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: () => setState(() => _accountOpen = false),
          child: Container(
            color: _C.ink.withOpacity(0.4),
            child: Center(
              child: GestureDetector(
                onTap: () {}, // absorb taps
                child: SingleChildScrollView(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    margin: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottomPadding),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: _C.card,
                      borderRadius: BorderRadius.circular(32),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 40, offset: const Offset(0, 16))],
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      // Header
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text('Account', style: _displayStyle(18, FontWeight.w700)),
                        _iconBtn(Icons.close, onTap: () => setState(() => _accountOpen = false)),
                      ]),
                      const SizedBox(height: 20),
                      // Profile card
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: _C.ink,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: const Color(0x66406040)),
                        ),
                        child: Row(children: [
                          _avatarCircle(56),
                          const SizedBox(width: 16),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(_identity.identity.deviceName, style: _displayStyle(16, FontWeight.w700, color: Colors.white)),
                            if (_sessionStore.isLoggedIn)
                              Text(_sessionStore.userEmail ?? '', style: TextStyle(fontSize: 12, color: Colors.white60)),
                            const SizedBox(height: 4),
                            Text(
                              _sessionStore.isLoggedIn ? 'PRO · ${_cloudDevices.length + 1} DEVICES' : 'FREE',
                              style: TextStyle(fontSize: 10, color: _C.primary, fontWeight: FontWeight.w700, letterSpacing: 1),
                            ),
                          ])),
                        ]),
                      ),
                      const SizedBox(height: 16),
                      // Settings rows
                      _accountRow(Icons.cloud_rounded, 'Cloud relay', _sessionStore.isLoggedIn ? 'Enabled — works across networks' : 'Login to enable'),
                      _accountRow(Icons.verified_user_rounded, 'Encryption', 'ed25519 · device-trusted'),
                      _accountRow(Icons.smartphone_rounded, 'This device', '${_identity.identity.deviceName} · LAN'),
                      const SizedBox(height: 16),
                      // Auth section
                      if (!_sessionStore.isLoggedIn) ...[
                        TextField(
                          controller: _emailController,
                          decoration: InputDecoration(
                            labelText: 'Email Address',
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                            prefixIcon: const Icon(Icons.email_outlined),
                          ),
                          keyboardType: TextInputType.emailAddress,
                        ),
                        const SizedBox(height: 12),
                        if (_codeSent) ...[
                          TextField(
                            controller: _codeController,
                            decoration: InputDecoration(
                              labelText: '6-digit Code',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                              prefixIcon: const Icon(Icons.lock_outline),
                            ),
                            keyboardType: TextInputType.number,
                          ),
                          const SizedBox(height: 12),
                          SizedBox(width: double.infinity, child: _primaryButton('Verify and Link', onPressed: () async {
                            try {
                              await _authService.verifyCode(_emailController.text.trim(), _codeController.text.trim());
                              _connectSignaling();
                              setState(() { _accountOpen = false; });
                              _showSuccessSnackBar('Logged in successfully!');
                            } catch (e) {
                              _showErrorSnackBar(e.toString());
                            }
                          })),
                        ] else
                          SizedBox(width: double.infinity, child: _primaryButton('Send Verification Code', onPressed: () async {
                            try {
                              await _authService.requestCode(_emailController.text.trim());
                              setState(() { _codeSent = true; });
                              _showSuccessSnackBar('Verification code sent!');
                            } catch (e) {
                              _showErrorSnackBar(e.toString());
                            }
                          })),
                      ] else ...[
                        // Sign out
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await _firebaseAuth.signOut();
                              _firebaseDevicesSubscription?.cancel();
                              _signalingSubscription?.cancel();
                              _signalingClient?.dispose();
                              _signalingClient = null;
                              _cloudDevices = [];
                              _codeSent = false;
                              _emailController.clear();
                              _codeController.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.logout, size: 18),
                            label: const Text('Sign out'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              side: const BorderSide(color: _C.border),
                            ),
                          ),
                        ),
                      ],
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _accountRow(IconData icon, String label, String sub) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: _C.primary.withOpacity(0.2), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 18, color: _C.ink),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            Text(sub, style: TextStyle(fontSize: 12, color: _C.muted)),
          ])),
          Icon(Icons.chevron_right, size: 18, color: _C.muted),
        ]),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  // Reusable primitives
  // ═══════════════════════════════════════════════════════

  Widget _avatarCircle(double size) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_C.primary, _C.primaryGlow]),
        border: Border.all(color: _C.primary.withOpacity(0.4), width: 2),
      ),
      child: Center(child: Text(
        _identity.identity.deviceName.isNotEmpty ? _identity.identity.deviceName[0].toUpperCase() : 'F',
        style: _displayStyle(size * 0.38, FontWeight.w800, color: _C.ink),
      )),
    );
  }

  Widget _iconBtn(IconData icon, {VoidCallback? onTap, Color color = _C.foreground, Color? bgColor}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bgColor ?? _C.secondaryBg,
        ),
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }

  Widget _primaryButton(String label, {VoidCallback? onPressed, IconData? icon}) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: _C.primary,
        foregroundColor: _C.ink,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        shadowColor: _C.primary.withOpacity(0.4),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      ]),
    );
  }

  Widget _emptyCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: _C.secondaryBg.withOpacity(0.4), borderRadius: BorderRadius.circular(16)),
      child: Center(child: Text(text, style: TextStyle(color: _C.muted, fontSize: 13))),
    );
  }

  static TextStyle _displayStyle(double size, FontWeight weight, {Color? color}) {
    return GoogleFonts.syne(fontSize: size, fontWeight: weight, color: color ?? _C.foreground, letterSpacing: -0.5);
  }

  Widget _buildDeezerLoginScreen() {
    final height = MediaQuery.of(context).size.height;
    final width = MediaQuery.of(context).size.width;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF0F1811), // Dark forest green background from styles.css
      body: Stack(
        children: [
          // ── Animated Wave Header at the Top ──
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: height * 0.43,
            child: AnimatedBuilder(
              animation: _loginWaveController,
              builder: (context, _) {
                return CustomPaint(
                  painter: AnimatedWavePainter(_loginWaveController.value),
                );
              },
            ),
          ),
          
          // ── Main Content Area ──
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(28, height * 0.43 - 20, 28, bottomPad + 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title text - uppercase left-aligned block like Archivo Black
                    Text(
                      'WELCOME\nTO FLASHY',
                      style: GoogleFonts.archivoBlack(
                        fontSize: 42,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        height: 0.95,
                        letterSpacing: -1.5,
                      ),
                    ),
                    const SizedBox(height: 32),
                    
                    // Primary email login button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _openEmailSignInSheet(),
                        icon: const Icon(Icons.mail_rounded, size: 20),
                        label: const Text('Continue with email or phone'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFB8E636), // flashy-green
                          foregroundColor: const Color(0xFF1E3320), // deep ink
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 20),
                    const Center(
                      child: Text(
                        'or',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Social login row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Apple icon
                        _socialIconRoundButton(
                          icon: const Icon(Icons.apple, color: Colors.white, size: 24),
                          onTap: () {}, // placeholder
                        ),
                        const SizedBox(width: 16),
                        // Google icon
                        _socialIconRoundButton(
                          icon: Text(
                            'G',
                            style: GoogleFonts.outfit(
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                            ),
                          ),
                          onTap: () => _signInWithGoogle(),
                        ),
                        const SizedBox(width: 16),
                        // Facebook icon
                        _socialIconRoundButton(
                          icon: const Icon(Icons.facebook_rounded, color: Color(0xFF1877F2), size: 24),
                          onTap: () {}, // placeholder
                        ),
                      ],
                    ),
                    
                    const Spacer(),

                    // Skip and use local P2P
                    Center(
                      child: TextButton(
                        onPressed: () {
                          setState(() {
                            _skippedLogin = true;
                          });
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white70,
                        ),
                        child: const Text(
                          'Skip and use local P2P',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Terms & Privacy Policy disclaimer
                    const Center(
                      child: Text(
                        "By continuing you agree to Flashy's Terms & Privacy Policy.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _socialIconRoundButton({required Widget icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF131F16), // oklch(0.20 0.02 150)
          border: Border.all(
            color: const Color(0xFF203325), // oklch(0.30 0.02 150)
            width: 1.5,
          ),
        ),
        child: Center(child: icon),
      ),
    );
  }

  /// Sign in with Google via Firebase.
  Future<void> _signInWithGoogle() async {
    try {
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => Center(
          child: Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: _C.primary),
                const SizedBox(height: 16),
                Text('Signing in...', style: TextStyle(color: _C.ink, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      );

      final user = await _firebaseAuth.signInWithGoogle();
      
      // Close loading dialog
      if (mounted) Navigator.of(context).pop();

      if (user != null) {
        _connectSignaling();
        _skippedLogin = true;
        setState(() {});
        _showSuccessSnackBar('Signed in as ${user.displayName ?? user.email}!');
      }
    } catch (e) {
      // Close loading dialog if open
      if (mounted) Navigator.of(context).pop();
      _showErrorSnackBar('Sign-in failed: ${e.toString()}');
    }
  }

  /// Open email/password sign-in bottom sheet.
  void _openEmailSignInSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final nameCtrl = TextEditingController();
        final emailCtrl = TextEditingController();
        final passwordCtrl = TextEditingController();
        bool isSignUp = true; // Toggle between sign up / sign in

        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF1E1E1E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.shield_outlined, size: 14, color: _C.primary),
                            const SizedBox(width: 6),
                            const Text(
                              'FIREBASE SECURE',
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white70, letterSpacing: 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      isSignUp ? 'Create your account' : 'Welcome back',
                      style: GoogleFonts.syne(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isSignUp
                          ? 'Sign up to link your devices and start sending.'
                          : 'Sign in to access your linked devices.',
                      style: const TextStyle(fontSize: 13, color: Colors.white54),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    // Name field (only for sign up)
                    if (isSignUp) ...[
                      TextField(
                        controller: nameCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Full Name',
                          labelStyle: const TextStyle(color: Colors.white54),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(color: Colors.white12),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(color: _C.primary),
                          ),
                          prefixIcon: const Icon(Icons.person_outline, color: Colors.white54),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    // Email field
                    TextField(
                      controller: emailCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Email Address',
                        labelStyle: const TextStyle(color: Colors.white54),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: Colors.white12),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: _C.primary),
                        ),
                        prefixIcon: const Icon(Icons.email_outlined, color: Colors.white54),
                      ),
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 16),
                    // Password field
                    TextField(
                      controller: passwordCtrl,
                      style: const TextStyle(color: Colors.white),
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        labelStyle: const TextStyle(color: Colors.white54),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: Colors.white12),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: _C.primary),
                        ),
                        prefixIcon: const Icon(Icons.lock_outline, color: Colors.white54),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Submit Button
                    ElevatedButton(
                      onPressed: () async {
                        final email = emailCtrl.text.trim();
                        final password = passwordCtrl.text.trim();
                        final name = nameCtrl.text.trim();

                        if (email.isEmpty || password.isEmpty || (isSignUp && name.isEmpty)) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please fill out all fields')),
                          );
                          return;
                        }

                        Navigator.pop(context); // Close sheet

                        try {
                          if (isSignUp) {
                            await _firebaseAuth.signUpWithEmail(email, password, name);
                          } else {
                            await _firebaseAuth.signInWithEmail(email, password);
                          }
                          _connectSignaling();
                          _skippedLogin = true;
                          setState(() {});
                          _showSuccessSnackBar('Logged in successfully!');
                        } catch (e) {
                          _showErrorSnackBar(e.toString());
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _C.primary,
                        foregroundColor: _C.ink,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        isSignUp ? 'Sign Up' : 'Sign In',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Toggle sign up / sign in
                    Center(
                      child: TextButton(
                        onPressed: () => setSheetState(() => isSignUp = !isSignUp),
                        child: Text(
                          isSignUp ? 'Already have an account? Sign In' : 'Need an account? Sign Up',
                          style: TextStyle(color: _C.primary, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _socialCircleButton(IconData icon, Color color, Color bgColor, {bool isGoogle = false}) {
    return Container(
      width: 52, height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.transparent,
        border: Border.all(color: _C.muted.withOpacity(0.3), width: 1.5),
      ),
      child: Center(
        child: isGoogle
          ? Text('G', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w900, color: _C.ink))
          : Icon(icon, color: _C.ink, size: 24),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
// Glow Pulse Orb (replaces radar scanner)
// ═══════════════════════════════════════════════════════
class _GlowPulseOrb extends StatefulWidget {
  const _GlowPulseOrb();

  @override
  State<_GlowPulseOrb> createState() => _GlowPulseOrbState();
}

class _GlowPulseOrbState extends State<_GlowPulseOrb> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final pulse = (math.sin(_ctrl.value * math.pi * 2) + 1) / 2;
        return Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _C.primary,
            boxShadow: [
              BoxShadow(color: _C.primary.withOpacity(0.3 + pulse * 0.3), blurRadius: 30 + pulse * 30),
              BoxShadow(color: _C.primary.withOpacity(0.15 + pulse * 0.15), blurRadius: 60 + pulse * 40),
            ],
          ),
          child: Center(
            child: Container(
              width: 70, height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _C.ink,
              ),
              child: Icon(Icons.bolt_rounded, size: 32, color: _C.primary),
            ),
          ),
        );
      },
    );
  }
}

class SpikyWaveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    final w = size.width;
    final h = size.height;

    // Start at top-left of the white area (around 38% down)
    path.moveTo(0, h * 0.38);

    // Single smooth wave across the width
    path.cubicTo(
      w * 0.25, h * 0.32, // control 1 – slightly up on left
      w * 0.35, h * 0.46, // control 2 – dips down in left-center
      w * 0.50, h * 0.40, // midpoint
    );
    path.cubicTo(
      w * 0.65, h * 0.34, // control 3 – rises on right-center
      w * 0.80, h * 0.42, // control 4 – dips slightly on right
      w,       h * 0.36,  // ends at right edge
    );

    // Close the bottom
    path.lineTo(w, h);
    path.lineTo(0, h);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class AnimatedWavePainter extends CustomPainter {
  final double val;

  AnimatedWavePainter(this.val);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 1. Draw radial glow spots (floating)
    final paintGlow = Paint();
    
    // Glow Circle 1
    final c1Center = Offset(
      (210 + math.sin(val * math.pi * 2) * 28) * (w / 1440),
      (96 + math.cos(val * math.pi * 2) * 16) * (h / 520),
    );
    final c1Radius = (68 + math.sin(val * math.pi * 2) * 5) * (w / 1440);
    paintGlow.shader = ui.Gradient.radial(
      c1Center,
      c1Radius,
      [Colors.white.withOpacity(0.12), Colors.transparent],
    );
    canvas.drawCircle(c1Center, c1Radius, paintGlow);

    // Glow Circle 2
    final c2Center = Offset(
      (1220 - math.sin(val * math.pi * 2) * 34) * (w / 1440),
      (142 + math.cos(val * math.pi * 2) * 18) * (h / 520),
    );
    final c2Radius = (94 + math.cos(val * math.pi * 2) * 6) * (w / 1440);
    paintGlow.shader = ui.Gradient.radial(
      c2Center,
      c2Radius,
      [Colors.white.withOpacity(0.12), Colors.transparent],
    );
    canvas.drawCircle(c2Center, c2Radius, paintGlow);

    // 2. Draw wave shadow with blur
    final shadowPath = Path();
    shadowPath.moveTo(0, 0);
    shadowPath.lineTo(w, 0);
    shadowPath.lineTo(w, h * (330 / 520));
    shadowPath.cubicTo(
      w * (1310 / 1440), h * (386 / 520),
      w * (1172 / 1440), h * (392 / 520),
      w * (1045 / 1440), h * (333 / 520),
    );
    shadowPath.cubicTo(
      w * (892 / 1440), h * (262 / 520),
      w * (758 / 1440), h * (260 / 520),
      w * (618 / 1440), h * (334 / 520),
    );
    shadowPath.cubicTo(
      w * (490 / 1440), h * (402 / 520),
      w * (350 / 1440), h * (402 / 520),
      w * (220 / 1440), h * (336 / 520),
    );
    shadowPath.cubicTo(
      w * (132 / 1440), h * (292 / 520),
      w * (56 / 1440), h * (286 / 520),
      0, h * (316 / 520),
    );
    shadowPath.close();

    final paintShadow = Paint()
      ..color = const Color(0xFFB8E636).withOpacity(0.25)
      ..imageFilter = ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18);
    canvas.drawPath(shadowPath, paintShadow);

    // 3. Draw main wave (interpolated)
    final H1 = (304 + (320 - 304) * val) * (h / 520);
    
    final wavePath = Path();
    wavePath.moveTo(0, 0);
    wavePath.lineTo(w, 0);
    wavePath.lineTo(w, H1);
    
    wavePath.cubicTo(
      w * ((1320 + (1310 - 1320) * val) / 1440), h * ((360 + (376 - 360) * val) / 520),
      w * ((1198 + (1190 - 1198) * val) / 1440), h * ((371 + (360 - 371) * val) / 520),
      w * ((1080 + (1062 - 1080) * val) / 1440), h * ((318 + (304 - 318) * val) / 520),
    );
    wavePath.cubicTo(
      w * ((936 + (916 - 936) * val) / 1440), h * ((254 + (241 - 254) * val) / 520),
      w * ((804 + (782 - 804) * val) / 1440), h * ((246 + (270 - 246) * val) / 520),
      w * ((666 + (646 - 666) * val) / 1440), h * ((318 + (336 - 318) * val) / 520),
    );
    wavePath.cubicTo(
      w * ((528 + (512 - 528) * val) / 1440), h * ((390 + (402 - 390) * val) / 520),
      w * ((380 + (366 - 380) * val) / 1440), h * ((389 + (374 - 389) * val) / 520),
      w * ((244 + (236 - 244) * val) / 1440), h * ((320 + (306 - 320) * val) / 520),
    );
    wavePath.cubicTo(
      w * ((146 + (142 - 146) * val) / 1440), h * ((270 + (258 - 270) * val) / 520),
      w * ((62 + (58 - 62) * val) / 1440), h * ((275 + (292 - 275) * val) / 520),
      0, h * ((314 + (336 - 314) * val) / 520),
    );
    wavePath.close();

    final paintWave = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(0, h),
        [
          const Color(0xFFD4F47A), // soft green
          const Color(0xFFB8E636), // mid green
          const Color(0xFF72B81F), // deep green
        ],
        [0.0, 0.58, 1.0],
      );
    canvas.drawPath(wavePath, paintWave);

    // 4. Draw wave highlight line
    final highlightPath = Path();
    highlightPath.moveTo(0, h * (248 / 520));
    highlightPath.cubicTo(
      w * (136 / 1440), h * (203 / 520),
      w * (244 / 1440), h * (228 / 520),
      w * (366 / 1440), h * (275 / 520),
    );
    highlightPath.cubicTo(
      w * (506 / 1440), h * (329 / 520),
      w * (628 / 1440), h * (314 / 520),
      w * (760 / 1440), h * (250 / 520),
    );
    highlightPath.cubicTo(
      w * (900 / 1440), h * (183 / 520),
      w * (1050 / 1440), h * (197 / 520),
      w * (1186 / 1440), h * (254 / 520),
    );
    highlightPath.cubicTo(
      w * (1292 / 1440), h * (298 / 520),
      w * (1374 / 1440), h * (296 / 520),
      w, h * (268 / 520),
    );
    highlightPath.lineTo(w, h * (310 / 520));
    highlightPath.cubicTo(
      w * (1328 / 1440), h * (360 / 520),
      w * (1208 / 1440), h * (354 / 520),
      w * (1086 / 1440), h * (304 / 520),
    );
    highlightPath.cubicTo(
      w * (936 / 1440), h * (242 / 520),
      w * (804 / 1440), h * (244 / 520),
      w * (666 / 1440), h * (311 / 520),
    );
    highlightPath.cubicTo(
      w * (528 / 1440), h * (378 / 520),
      w * (388 / 1440), h * (376 / 520),
      w * (248 / 1440), h * (312 / 520),
    );
    highlightPath.cubicTo(
      w * (142 / 1440), h * (263 / 520),
      w * (62 / 1440), h * (262 / 520),
      0, h * (300 / 520),
    );
    highlightPath.close();

    canvas.save();
    canvas.translate(0, 10 * math.sin(val * math.pi * 2));
    final paintHighlight = Paint()
      ..color = Colors.white.withOpacity(0.20)
      ..style = PaintingStyle.fill;
    canvas.drawPath(highlightPath, paintHighlight);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AnimatedWavePainter oldDelegate) {
    return oldDelegate.val != val;
  }
}
