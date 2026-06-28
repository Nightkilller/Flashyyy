import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'connection.dart';

/// A secure TLS-socket-based [Connection] implementation for LAN direct transfer.
class TlsConnection implements Connection {
  final SecureSocket _secureSocket;
  final StreamController<Uint8List> _incomingController =
      StreamController<Uint8List>.broadcast();
  bool _connected = true;

  TlsConnection(this._secureSocket) {
    _secureSocket.listen(
      (data) {
        if (!_incomingController.isClosed) {
          _incomingController.add(Uint8List.fromList(data));
        }
      },
      onDone: () {
        _connected = false;
        if (!_incomingController.isClosed) {
          _incomingController.close();
        }
      },
      onError: (Object error) {
        _connected = false;
        if (!_incomingController.isClosed) {
          _incomingController.addError(error);
          _incomingController.close();
        }
      },
    );
  }

  @override
  bool get isConnected => _connected;

  @override
  Future<void> sendBytes(Uint8List data) async {
    if (!_connected) {
      throw const ConnectionClosedException();
    }
    _secureSocket.add(data);
    await _secureSocket.flush();
  }

  @override
  Stream<Uint8List> get incomingBytes => _incomingController.stream;

  @override
  Future<void> close() async {
    _connected = false;
    try {
      await _secureSocket.flush();
      await _secureSocket.close();
    } catch (_) {
      // Best-effort close
    } finally {
      if (!_incomingController.isClosed) {
        await _incomingController.close();
      }
    }
  }

  /// Exposes the remote address for debugging/logging.
  String get remoteAddress => _secureSocket.address.address;

  /// Exposes the remote port for debugging/logging.
  int get remotePort => _secureSocket.remotePort;
}
