import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../identity/keypair_manager.dart';

/// Client that maintains a persistent WebSocket connection to the signaling server.
/// Exposes streams of signaling events and auto-reconnects with heartbeat mechanisms.
class SignalingClient {
  final Uri serverUri;
  final KeypairManager identityManager;
  final String? sessionToken;

  WebSocketChannel? _channel;
  bool _isDisposed = false;
  bool _isConnected = false;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  SignalingClient({
    required this.serverUri,
    required this.identityManager,
    this.sessionToken,
  });

  /// Stream of all incoming WebSocket messages parsed as JSON maps.
  Stream<Map<String, dynamic>> get incomingMessages => _messageController.stream;

  /// Returns true if currently connected to the server.
  bool get isConnected => _isConnected;

  /// Connects to the signaling server.
  Future<void> connect() async {
    if (_isDisposed || _isConnected) return;

    try {
      _channel = WebSocketChannel.connect(serverUri);
      
      // Wait for the channel to be ready if platform supports it
      await _channel!.ready;
      _isConnected = true;
      _reconnectAttempts = 0;

      // 1. Send registration payload
      _register();

      // 2. Start heartbeat
      _startHeartbeat();

      // 3. Listen for incoming messages
      _channel!.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message as String) as Map<String, dynamic>;
            _messageController.add(data);
          } catch (_) {
            // Bad message formats ignored
          }
        },
        onDone: () => _handleDisconnect(),
        onError: (Object error) => _handleDisconnect(),
      );
    } catch (_) {
      _handleDisconnect();
    }
  }

  /// Sends register action to declare presence.
  void _register() {
    send('register', {
      'deviceId': identityManager.identity.deviceId,
      'deviceName': identityManager.identity.deviceName,
      'deviceType': identityManager.identity.deviceType,
      'publicKey': identityManager.publicKeyHex,
      'sessionToken': sessionToken,
    });
  }

  /// Starts a periodic heartbeat to prevent TCP timeout.
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_isConnected) {
        send('heartbeat', {
          'deviceId': identityManager.identity.deviceId,
        });
      }
    });
  }

  /// Handles disconnection gracefully by clearing state and scheduling reconnect.
  void _handleDisconnect() {
    _isConnected = false;
    _heartbeatTimer?.cancel();
    _channel?.sink.close();
    _channel = null;

    if (!_isDisposed) {
      _scheduleReconnect();
    }
  }

  /// Reconnect with exponential backoff capping at 30 seconds.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    final backoffSec = (_reconnectAttempts * 2).clamp(2, 30);
    
    _reconnectTimer = Timer(Duration(seconds: backoffSec), () {
      connect();
    });
  }

  /// Sends a structured message over the WebSocket connection.
  void send(String action, Map<String, dynamic> payload) {
    if (!_isConnected || _channel == null) return;
    try {
      _channel!.sink.add(jsonEncode({
        'action': action,
        'payload': payload,
      }));
    } catch (_) {
      _handleDisconnect();
    }
  }

  /// Relays signaling or data signals to another device via the server.
  void sendRelayMessage(String targetDeviceId, Map<String, dynamic> signal) {
    send('relay', {
      'targetDeviceId': targetDeviceId,
      'signal': signal,
    });
  }

  /// Disposes resources and closes WebSocket.
  Future<void> dispose() async {
    _isDisposed = true;
    _isConnected = false;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    await _channel?.sink.close();
    await _messageController.close();
  }
}
