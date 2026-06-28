import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'connection.dart';

/// A TCP-socket-based [Connection] implementation for testing on localhost.
///
/// This is NOT used in production — it exists solely so we can test the
/// full transfer engine (chunking, resume, checksums) end-to-end on a
/// single machine without any external dependencies.
class LocalhostConnection implements Connection {
  final Socket _socket;
  final StreamController<Uint8List> _incomingController =
      StreamController<Uint8List>.broadcast();
  bool _connected = true;

  LocalhostConnection._(this._socket) {
    _socket.listen(
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
  Future<void> sendBytes(Uint8List data) async {
    if (!_connected) {
      throw const ConnectionClosedException();
    }
    _socket.add(data);
    await _socket.flush();
  }

  @override
  Stream<Uint8List> get incomingBytes => _incomingController.stream;

  @override
  Future<void> close() async {
    _connected = false;
    try {
      await _socket.flush();
      await _socket.close();
    } catch (_) {
      // Best-effort close — socket may already be dead
    }
    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
  }

  @override
  bool get isConnected => _connected;
}

/// A localhost TCP server that accepts a single connection.
///
/// Usage:
/// ```dart
/// final server = await LocalhostServer.start();
/// print('Listening on port ${server.port}');
/// final serverConnection = await server.acceptConnection();
/// // ... use serverConnection ...
/// await server.stop();
/// ```
class LocalhostServer {
  final ServerSocket _serverSocket;
  final Completer<LocalhostConnection> _connectionCompleter =
      Completer<LocalhostConnection>();

  LocalhostServer._(this._serverSocket) {
    _serverSocket.listen((socket) {
      if (!_connectionCompleter.isCompleted) {
        _connectionCompleter.complete(LocalhostConnection._(socket));
      } else {
        // Only accept one connection; reject any extras
        socket.close();
      }
    });
  }

  /// Starts a localhost TCP server on a random available port.
  static Future<LocalhostServer> start() async {
    final serverSocket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0, // OS assigns a random available port
    );
    return LocalhostServer._(serverSocket);
  }

  /// The port the server is listening on.
  int get port => _serverSocket.port;

  /// Waits for a single client to connect and returns the [Connection].
  Future<LocalhostConnection> acceptConnection() => _connectionCompleter.future;

  /// Stops the server socket.
  Future<void> stop() async {
    await _serverSocket.close();
  }
}

/// Connects to a localhost TCP server and returns a [Connection].
class LocalhostClient {
  /// Connects to the given [host] and [port] and returns a [Connection].
  static Future<LocalhostConnection> connect(String host, int port) async {
    final socket = await Socket.connect(host, port);
    return LocalhostConnection._(socket);
  }
}
