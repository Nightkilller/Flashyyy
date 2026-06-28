import 'dart:typed_data';

/// Abstract interface for a bidirectional byte-stream connection.
///
/// All transport layers (localhost TCP, LAN direct, WebRTC data channel)
/// implement this interface. The [TransferManager] operates exclusively
/// through this abstraction — it never knows or cares which transport
/// is active underneath.
abstract class Connection {
  /// Sends raw bytes to the remote peer.
  ///
  /// Throws [ConnectionClosedException] if the connection has been closed.
  Future<void> sendBytes(Uint8List data);

  /// A stream of incoming byte buffers from the remote peer.
  ///
  /// Each event is a single buffer as received from the underlying transport.
  /// Consumers must handle message framing themselves (the [TransferManager]
  /// uses length-prefixed framing on top of this raw stream).
  Stream<Uint8List> get incomingBytes;

  /// Closes the connection gracefully.
  ///
  /// After calling this, [isConnected] returns false and [sendBytes] will
  /// throw. The [incomingBytes] stream will be closed.
  Future<void> close();

  /// Whether the connection is currently open and usable.
  bool get isConnected;
}

/// Thrown when attempting to use a connection that has been closed.
class ConnectionClosedException implements Exception {
  final String message;
  const ConnectionClosedException([this.message = 'Connection is closed']);

  @override
  String toString() => 'ConnectionClosedException: $message';
}
