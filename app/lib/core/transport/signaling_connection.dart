import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../signaling/signaling_client.dart';
import 'connection.dart';

/// A virtual cross-network [Connection] implementation that relays encrypted data
/// packets through the WebSocket Signaling Server.
class SignalingConnection implements Connection {
  final SignalingClient _signalingClient;
  final String _peerDeviceId;
  final StreamController<Uint8List> _incomingController =
      StreamController<Uint8List>.broadcast();
  
  bool _connected = true;
  StreamSubscription<Map<String, dynamic>>? _signalingSubscription;

  SignalingConnection(this._signalingClient, this._peerDeviceId) {
    // Listen to signaling messages and filter for relay data from our peer
    _signalingSubscription = _signalingClient.incomingMessages.listen(
      (msg) {
        if (msg['action'] == 'relay') {
          final payload = msg['payload'] as Map<String, dynamic>;
          final senderDeviceId = payload['senderDeviceId'] as String;
          
          if (senderDeviceId == _peerDeviceId) {
            final signal = payload['signal'] as Map<String, dynamic>;
            final type = signal['type'] as String;

            if (type == 'data') {
              final bytesBase64 = signal['bytes'] as String;
              final bytes = base64Decode(bytesBase64);
              if (!_incomingController.isClosed) {
                _incomingController.add(bytes);
              }
            } else if (type == 'close') {
              _closeInternal();
            }
          }
        }
      },
      onError: (Object err) {
        _closeInternal();
        if (!_incomingController.isClosed) {
          _incomingController.addError(err);
        }
      },
      onDone: () {
        _closeInternal();
      },
    );
  }

  @override
  bool get isConnected => _connected && _signalingClient.isConnected;

  @override
  Future<void> sendBytes(Uint8List data) async {
    if (!isConnected) {
      throw const ConnectionClosedException();
    }
    // Encode bytes to base64 to transmit over the WebSocket JSON channel
    final bytesBase64 = base64Encode(data);
    _signalingClient.sendRelayMessage(_peerDeviceId, {
      'type': 'data',
      'bytes': bytesBase64,
    });
  }

  @override
  Stream<Uint8List> get incomingBytes => _incomingController.stream;

  @override
  Future<void> close() async {
    if (!_connected) return;
    try {
      // Send close command to peer so they shut down their transfer manager
      _signalingClient.sendRelayMessage(_peerDeviceId, {
        'type': 'close',
      });
    } catch (_) {
      // Best-effort send
    }
    await _closeInternal();
  }

  Future<void> _closeInternal() async {
    if (!_connected) return;
    _connected = false;
    await _signalingSubscription?.cancel();
    _signalingSubscription = null;
    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
  }

  /// Exposes the remote address description.
  String get remoteAddress => 'Cloud Proxy Relay';

  /// Exposes a virtual port.
  int get remotePort => 443;
}
