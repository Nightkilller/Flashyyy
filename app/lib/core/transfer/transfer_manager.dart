import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../transport/connection.dart';
import 'file_chunker.dart';
import 'resume_state_store.dart';

// ─── Protocol Message Types ────────────────────────────────────────────────
// Each message over the connection is framed as:
//   [4 bytes: big-endian payload length] [1 byte: type tag] [payload bytes]

/// Message type tags for the transfer protocol.
class MessageType {
  static const int manifest = 0x01;
  static const int fileChunk = 0x02;
  static const int ack = 0x03;
  static const int transferComplete = 0x04;
  static const int verifyOk = 0x05;
  static const int verifyFailed = 0x06;
  static const int transferRequest = 0x07;

  MessageType._();
}

/// A parsed protocol message.
class ProtocolMessage {
  final int type;
  final Uint8List payload;

  const ProtocolMessage({required this.type, required this.payload});
}

// ─── Message Reader ────────────────────────────────────────────────────────

/// Reads length-prefixed protocol messages from a [Connection]'s byte stream.
///
/// This class solves the critical problem of TCP fragmentation: data from
/// [Connection.incomingBytes] arrives in arbitrary-sized chunks that don't
/// align with protocol message boundaries. The reader buffers incoming data
/// and yields complete framed messages.
///
/// It maintains a **single persistent subscription** to the connection's
/// incoming stream, so no data is lost between successive [readMessage] calls.
class MessageReader {
  final Connection _connection;
  StreamSubscription<Uint8List>? _subscription;
  bool _connectionClosed = false;

  // We accumulate raw bytes into this list and track how far we've consumed
  final List<int> _buffer = [];

  // A completer that readMessage awaits when it needs more data.
  // When new data arrives, the completer is completed to wake readMessage.
  Completer<void>? _waitingForData;

  MessageReader(this._connection) {
    _subscription = _connection.incomingBytes.listen(
      (data) {
        _buffer.addAll(data);
        // Wake up readMessage if it's waiting
        if (_waitingForData != null && !_waitingForData!.isCompleted) {
          _waitingForData!.complete();
        }
      },
      onDone: () {
        _connectionClosed = true;
        if (_waitingForData != null && !_waitingForData!.isCompleted) {
          _waitingForData!.complete();
        }
      },
      onError: (Object error) {
        _connectionClosed = true;
        if (_waitingForData != null && !_waitingForData!.isCompleted) {
          _waitingForData!.completeError(error);
        }
      },
    );
  }

  /// Reads the next complete protocol message from the connection.
  ///
  /// Blocks until a full message (header + payload) is available.
  /// Throws [ConnectionClosedException] if the connection closes before
  /// a complete message arrives.
  Future<ProtocolMessage> readMessage() async {
    while (true) {
      // Try to parse a complete message from buffered data
      final parsed = _tryParse();
      if (parsed != null) return parsed;

      // Not enough data yet — wait for more
      if (_connectionClosed) {
        throw const ConnectionClosedException(
          'Connection closed while waiting for message',
        );
      }

      _waitingForData = Completer<void>();
      await _waitingForData!.future;
    }
  }

  /// Tries to parse a complete message from the internal buffer.
  /// Returns null if not enough data is available yet.
  /// On success, consumes the parsed bytes from the buffer.
  ProtocolMessage? _tryParse() {
    if (_buffer.length < 5) return null; // Need at least header

    final headerData = ByteData.sublistView(Uint8List.fromList(_buffer.sublist(0, 5)));
    final payloadLength = headerData.getUint32(0, Endian.big);
    final totalLength = 5 + payloadLength;

    if (_buffer.length < totalLength) return null; // Incomplete payload

    final type = headerData.getUint8(4);
    final payload = Uint8List.fromList(_buffer.sublist(5, totalLength));

    // Consume parsed bytes from buffer
    _buffer.removeRange(0, totalLength);

    return ProtocolMessage(type: type, payload: payload);
  }

  /// Disposes the reader and cancels the stream subscription.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _connectionClosed = true;
    // Wake up any waiting readMessage call
    if (_waitingForData != null && !_waitingForData!.isCompleted) {
      _waitingForData!.complete();
    }
  }
}

// ─── Transfer Progress Callback ────────────────────────────────────────────

/// Callback for reporting transfer progress.
typedef TransferProgressCallback = void Function(TransferProgress progress);

/// Snapshot of transfer progress at a point in time.
class TransferProgress {
  final String transferId;
  final int totalBytes;
  final int transferredBytes;
  final int currentFileIndex;
  final int totalFiles;
  final String currentFileName;

  const TransferProgress({
    required this.transferId,
    required this.totalBytes,
    required this.transferredBytes,
    required this.currentFileIndex,
    required this.totalFiles,
    required this.currentFileName,
  });

  double get fraction =>
      totalBytes > 0 ? transferredBytes / totalBytes : 1.0;
}

// ─── Transfer Result ───────────────────────────────────────────────────────

/// The outcome of a completed transfer.
class TransferResult {
  final String transferId;
  final bool success;
  final String? errorMessage;
  final List<String>? failedFiles;

  const TransferResult({
    required this.transferId,
    required this.success,
    this.errorMessage,
    this.failedFiles,
  });
}

// ─── TransferManager ───────────────────────────────────────────────────────

/// Orchestrates sending and receiving files over a [Connection].
///
/// The manager uses a simple length-prefixed binary protocol on top of the
/// raw byte stream provided by [Connection]. It supports:
/// - Single files and folder trees (via [TransferManifest])
/// - Resume after interruption (via [ResumeStateStore])
/// - SHA-256 integrity verification on the receiver side
/// - Real-time progress reporting via callbacks
class TransferManager {
  final FileChunker _chunker;
  final ResumeStateStore _resumeStore;

  TransferManager({
    FileChunker? chunker,
    required ResumeStateStore resumeStore,
  }) : _chunker = chunker ?? const FileChunker(),
        _resumeStore = resumeStore;

  // ── Sending ────────────────────────────────────────────────────────────

  /// Sends a single file over [connection].
  ///
  /// [filePath] must be an absolute path to an existing file.
  /// Returns a [TransferResult] indicating success or failure.
  Future<TransferResult> sendFile(
    Connection connection,
    String filePath, {
    TransferProgressCallback? onProgress,
  }) async {
    final manifest = await _chunker.generateManifestForFile(filePath);
    return _sendWithManifest(
      connection,
      manifest,
      {0: filePath},
      onProgress: onProgress,
    );
  }

  /// Sends an entire directory tree over [connection].
  ///
  /// [dirPath] must be an absolute path to an existing directory.
  Future<TransferResult> sendDirectory(
    Connection connection,
    String dirPath, {
    TransferProgressCallback? onProgress,
  }) async {
    final manifest = await _chunker.generateManifestForDirectory(dirPath);

    // Build a map from fileIndex → absolute path for chunking
    final filePathMap = <int, String>{};
    for (var i = 0; i < manifest.files.length; i++) {
      filePathMap[i] = p.join(dirPath, manifest.files[i].relativePath);
    }

    return _sendWithManifest(
      connection,
      manifest,
      filePathMap,
      onProgress: onProgress,
    );
  }

  /// Resumes a previously interrupted send.
  ///
  /// [manifest] and [filePathMap] must match the original transfer.
  Future<TransferResult> resumeSend(
    Connection connection,
    TransferManifest manifest,
    Map<int, String> filePathMap, {
    TransferProgressCallback? onProgress,
  }) async {
    return _sendWithManifest(
      connection,
      manifest,
      filePathMap,
      onProgress: onProgress,
    );
  }

  Future<TransferResult> _sendWithManifest(
    Connection connection,
    TransferManifest manifest,
    Map<int, String> filePathMap, {
    TransferProgressCallback? onProgress,
  }) async {
    final transferId = manifest.transferId;
    int totalTransferred = 0;
    final reader = MessageReader(connection);

    try {
      // Save manifest for resume tracking
      await _resumeStore.saveManifest(transferId, manifest, 'send');

      // 1. Send manifest
      final manifestJson = jsonEncode(manifest.toJson());
      await _sendMessage(
        connection,
        MessageType.manifest,
        Uint8List.fromList(utf8.encode(manifestJson)),
      );

      // 2. Stream file chunks, skipping already-acknowledged ones
      for (var fileIdx = 0; fileIdx < manifest.files.length; fileIdx++) {
        final filePath = filePathMap[fileIdx]!;
        final fileEntry = manifest.files[fileIdx];

        // Check resume state
        final resumeOffset =
            await _resumeStore.getResumeOffset(transferId, fileIdx);
        final startOffset = resumeOffset ?? 0;

        // Account for already-transferred bytes in progress
        totalTransferred += startOffset;

        await for (final chunk in _chunker.chunkFile(
          filePath,
          fileIndex: fileIdx,
          startOffset: startOffset,
        )) {
          // Send chunk
          await _sendChunk(connection, chunk);

          // Wait for ACK
          final ackMsg = await reader.readMessage();
          if (ackMsg.type != MessageType.ack) {
            throw TransferException(
              'Expected ACK, got message type ${ackMsg.type}',
            );
          }

          // Parse ACK and update resume state
          final ackData = jsonDecode(utf8.decode(ackMsg.payload));
          final ackedOffset = (ackData['offset'] as int) +
              (ackData['length'] as int);
          await _resumeStore.updateProgress(
            transferId,
            fileIdx,
            ackedOffset,
          );

          totalTransferred += chunk.length;
          onProgress?.call(TransferProgress(
            transferId: transferId,
            totalBytes: manifest.totalBytes,
            transferredBytes: totalTransferred,
            currentFileIndex: fileIdx,
            totalFiles: manifest.files.length,
            currentFileName: fileEntry.relativePath,
          ));
        }

        await _resumeStore.markFileCompleted(transferId, fileIdx);
      }

      // 3. Send TransferComplete
      await _sendMessage(
        connection,
        MessageType.transferComplete,
        Uint8List(0),
      );

      // 4. Wait for verification result
      final verifyMsg = await reader.readMessage();
      if (verifyMsg.type == MessageType.verifyOk) {
        await _resumeStore.markTransferCompleted(transferId);
        await reader.dispose();
        return TransferResult(transferId: transferId, success: true);
      } else if (verifyMsg.type == MessageType.verifyFailed) {
        final failedInfo = jsonDecode(utf8.decode(verifyMsg.payload));
        await reader.dispose();
        return TransferResult(
          transferId: transferId,
          success: false,
          errorMessage: 'Checksum verification failed on receiver',
          failedFiles: (failedInfo['failedFiles'] as List?)
              ?.cast<String>(),
        );
      } else {
        await reader.dispose();
        return TransferResult(
          transferId: transferId,
          success: false,
          errorMessage:
              'Unexpected message type ${verifyMsg.type} after transfer',
        );
      }
    } on ConnectionClosedException {
      await reader.dispose();
      return TransferResult(
        transferId: transferId,
        success: false,
        errorMessage: 'Connection lost — transfer can be resumed',
      );
    } catch (e) {
      await reader.dispose();
      return TransferResult(
        transferId: transferId,
        success: false,
        errorMessage: e.toString(),
      );
    }
  }

  // ── Receiving ──────────────────────────────────────────────────────────

  /// Receives files from [connection] and writes them to [outputDir].
  ///
  /// The receiver:
  /// 1. Receives the manifest
  /// 2. Receives chunks, writes them to disk, sends ACKs
  /// 3. After all chunks received, verifies SHA-256 checksums
  /// 4. Sends VerifyOK or VerifyFailed
  Future<TransferResult> receiveFiles(
    Connection connection,
    String outputDir, {
    TransferProgressCallback? onProgress,
  }) async {
    int totalTransferred = 0;
    final reader = MessageReader(connection);

    try {
      // 1. Receive manifest
      final manifestMsg = await reader.readMessage();
      if (manifestMsg.type != MessageType.manifest) {
        throw TransferException(
          'Expected manifest, got message type ${manifestMsg.type}',
        );
      }

      final manifestJson = jsonDecode(utf8.decode(manifestMsg.payload));
      final manifest = TransferManifest.fromJson(
        manifestJson as Map<String, dynamic>,
      );
      final transferId = manifest.transferId;

      // Save manifest for resume tracking
      await _resumeStore.saveManifest(transferId, manifest, 'receive');

      // Prepare file handles
      final fileHandles = <int, RandomAccessFile>{};

      try {
        // 2. Receive chunks until TransferComplete
        while (true) {
          final msg = await reader.readMessage();

          if (msg.type == MessageType.transferComplete) {
            break;
          }

          if (msg.type != MessageType.fileChunk) {
            throw TransferException(
              'Expected file chunk or transfer complete, '
              'got message type ${msg.type}',
            );
          }

          // Parse chunk
          final chunk = _deserializeChunk(msg.payload);

          // Get or create file handle
          if (!fileHandles.containsKey(chunk.fileIndex)) {
            final fileEntry = manifest.files[chunk.fileIndex];
            final outPath = p.join(outputDir, fileEntry.relativePath);

            // Create parent directories
            await Directory(p.dirname(outPath)).create(recursive: true);

            // Open file for writing
            final file = File(outPath);
            final mode = chunk.offset == 0
                ? FileMode.write
                : FileMode.writeOnlyAppend;
            fileHandles[chunk.fileIndex] = await file.open(mode: mode);
          }

          final raf = fileHandles[chunk.fileIndex]!;

          // Seek and write
          await raf.setPosition(chunk.offset);
          await raf.writeFrom(chunk.data);

          totalTransferred += chunk.length;

          // Update resume state
          final ackedOffset = chunk.offset + chunk.length;
          await _resumeStore.updateProgress(
            transferId,
            chunk.fileIndex,
            ackedOffset,
          );

          // Send ACK
          final ackPayload = jsonEncode({
            'fileIndex': chunk.fileIndex,
            'chunkIndex': chunk.chunkIndex,
            'offset': chunk.offset,
            'length': chunk.length,
          });
          await _sendMessage(
            connection,
            MessageType.ack,
            Uint8List.fromList(utf8.encode(ackPayload)),
          );

          onProgress?.call(TransferProgress(
            transferId: transferId,
            totalBytes: manifest.totalBytes,
            transferredBytes: totalTransferred,
            currentFileIndex: chunk.fileIndex,
            totalFiles: manifest.files.length,
            currentFileName: manifest.files[chunk.fileIndex].relativePath,
          ));
        }

        // Close all file handles before checksum verification
        for (final raf in fileHandles.values) {
          await raf.close();
        }
        fileHandles.clear();

        // 3. Verify checksums
        final failedFiles = <String>[];
        for (var i = 0; i < manifest.files.length; i++) {
          final entry = manifest.files[i];
          final outPath = p.join(outputDir, entry.relativePath);
          final ok = await _chunker.verifyChecksum(
            outPath,
            entry.sha256Checksum,
          );
          if (!ok) {
            failedFiles.add(entry.relativePath);
          }
          await _resumeStore.markFileCompleted(transferId, i);
        }

        // 4. Send verification result
        if (failedFiles.isEmpty) {
          await _sendMessage(
            connection,
            MessageType.verifyOk,
            Uint8List(0),
          );
          await _resumeStore.markTransferCompleted(transferId);
          await reader.dispose();
          return TransferResult(transferId: transferId, success: true);
        } else {
          final failPayload = jsonEncode({'failedFiles': failedFiles});
          await _sendMessage(
            connection,
            MessageType.verifyFailed,
            Uint8List.fromList(utf8.encode(failPayload)),
          );
          await reader.dispose();
          return TransferResult(
            transferId: transferId,
            success: false,
            errorMessage: 'Checksum failed for ${failedFiles.length} file(s)',
            failedFiles: failedFiles,
          );
        }
      } finally {
        for (final raf in fileHandles.values) {
          try {
            await raf.close();
          } catch (_) {}
        }
      }
    } on ConnectionClosedException {
      await reader.dispose();
      return TransferResult(
        transferId: 'unknown',
        success: false,
        errorMessage: 'Connection lost — transfer can be resumed',
      );
    } catch (e) {
      await reader.dispose();
      return TransferResult(
        transferId: 'unknown',
        success: false,
        errorMessage: e.toString(),
      );
    }
  }

  // ── Protocol Framing ──────────────────────────────────────────────────

  /// Sends a framed protocol message:
  ///   [4 bytes: payload length (big-endian)] [1 byte: type] [payload]
  Future<void> _sendMessage(
    Connection connection,
    int type,
    Uint8List payload,
  ) async {
    final header = ByteData(5);
    header.setUint32(0, payload.length, Endian.big);
    header.setUint8(4, type);

    final frame = Uint8List(5 + payload.length);
    frame.setRange(0, 5, header.buffer.asUint8List());
    frame.setRange(5, 5 + payload.length, payload);

    await connection.sendBytes(frame);
  }

  /// Serializes a [FileChunk] into a binary payload and sends it.
  ///
  /// Chunk binary format:
  ///   [4 bytes: fileIndex] [4 bytes: chunkIndex] [8 bytes: offset]
  ///   [4 bytes: data length] [data bytes]
  Future<void> _sendChunk(Connection connection, FileChunk chunk) async {
    final header = ByteData(20);
    header.setUint32(0, chunk.fileIndex, Endian.big);
    header.setUint32(4, chunk.chunkIndex, Endian.big);
    // 64-bit offset split into two 32-bit writes for compatibility
    header.setUint32(8, (chunk.offset >> 32) & 0xFFFFFFFF, Endian.big);
    header.setUint32(12, chunk.offset & 0xFFFFFFFF, Endian.big);
    header.setUint32(16, chunk.data.length, Endian.big);

    final payload = Uint8List(20 + chunk.data.length);
    payload.setRange(0, 20, header.buffer.asUint8List());
    payload.setRange(20, 20 + chunk.data.length, chunk.data);

    await _sendMessage(connection, MessageType.fileChunk, payload);
  }

  /// Deserializes a binary payload into a [FileChunk].
  FileChunk _deserializeChunk(Uint8List payload) {
    final data = ByteData.sublistView(payload);
    final fileIndex = data.getUint32(0, Endian.big);
    final chunkIndex = data.getUint32(4, Endian.big);
    final offsetHigh = data.getUint32(8, Endian.big);
    final offsetLow = data.getUint32(12, Endian.big);
    final offset = (offsetHigh << 32) | offsetLow;
    final dataLength = data.getUint32(16, Endian.big);
    final chunkData = Uint8List.sublistView(payload, 20, 20 + dataLength);

    return FileChunk(
      fileIndex: fileIndex,
      chunkIndex: chunkIndex,
      offset: offset,
      data: chunkData,
    );
  }
}

/// Exception thrown by the transfer protocol.
class TransferException implements Exception {
  final String message;
  const TransferException(this.message);

  @override
  String toString() => 'TransferException: $message';
}
