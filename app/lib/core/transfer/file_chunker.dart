import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Default chunk size: 512KB
const int kDefaultChunkSize = 512 * 1024;

/// Represents a single chunk of file data being transferred.
class FileChunk {
  /// Index of this file within the transfer manifest.
  final int fileIndex;

  /// Sequential chunk number within this file (0-based).
  final int chunkIndex;

  /// Byte offset within the file where this chunk starts.
  final int offset;

  /// The actual bytes of this chunk.
  final Uint8List data;

  /// Length of [data] in bytes.
  int get length => data.length;

  const FileChunk({
    required this.fileIndex,
    required this.chunkIndex,
    required this.offset,
    required this.data,
  });
}

/// Metadata for a single file in a transfer manifest.
class FileEntry {
  /// Path relative to the transfer root (never absolute — security requirement).
  final String relativePath;

  /// Total size of the file in bytes.
  final int sizeBytes;

  /// SHA-256 hex digest of the complete file.
  final String sha256Checksum;

  const FileEntry({
    required this.relativePath,
    required this.sizeBytes,
    required this.sha256Checksum,
  });

  Map<String, dynamic> toJson() => {
        'relativePath': relativePath,
        'sizeBytes': sizeBytes,
        'sha256Checksum': sha256Checksum,
      };

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
        relativePath: json['relativePath'] as String,
        sizeBytes: json['sizeBytes'] as int,
        sha256Checksum: json['sha256Checksum'] as String,
      );
}

/// A manifest describing all files in a transfer.
///
/// The manifest is sent to the receiver before any file data, so the
/// receiver knows what to expect (file names, sizes, checksums for
/// integrity verification).
class TransferManifest {
  /// Unique ID for this transfer session.
  final String transferId;

  /// Ordered list of files in this transfer.
  final List<FileEntry> files;

  /// Sum of all file sizes.
  final int totalBytes;

  /// When this manifest was created.
  final DateTime createdAt;

  const TransferManifest({
    required this.transferId,
    required this.files,
    required this.totalBytes,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'transferId': transferId,
        'files': files.map((f) => f.toJson()).toList(),
        'totalBytes': totalBytes,
        'createdAt': createdAt.toIso8601String(),
      };

  factory TransferManifest.fromJson(Map<String, dynamic> json) {
    final files = (json['files'] as List)
        .map((f) => FileEntry.fromJson(f as Map<String, dynamic>))
        .toList();
    return TransferManifest(
      transferId: json['transferId'] as String,
      files: files,
      totalBytes: json['totalBytes'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

/// Handles file chunking, manifest generation, and streaming SHA-256 hashing.
///
/// This class never loads an entire file into memory — it streams data
/// in configurable chunks (default 512KB), making it safe for files of
/// any size.
class FileChunker {
  final int chunkSize;

  const FileChunker({this.chunkSize = kDefaultChunkSize});

  /// Generates a [TransferManifest] for a single file.
  ///
  /// The [relativeName] is used as the file's relative path in the manifest
  /// (defaults to the file's basename if not provided).
  Future<TransferManifest> generateManifestForFile(
    String filePath, {
    String? relativeName,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }

    final stat = await file.stat();
    final checksum = await _computeSha256(file);
    final entry = FileEntry(
      relativePath: relativeName ?? p.basename(filePath),
      sizeBytes: stat.size,
      sha256Checksum: checksum,
    );

    return TransferManifest(
      transferId: const Uuid().v4(),
      files: [entry],
      totalBytes: stat.size,
      createdAt: DateTime.now(),
    );
  }

  /// Generates a [TransferManifest] for an entire directory tree.
  ///
  /// Walks [dirPath] recursively, recording every file with its path
  /// relative to [dirPath]. Directories are not listed explicitly — they
  /// are implied by the file paths and will be recreated on the receiver.
  Future<TransferManifest> generateManifestForDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      throw FileSystemException('Directory not found', dirPath);
    }

    final files = <FileEntry>[];
    int totalBytes = 0;

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final relativePath = p.relative(entity.path, from: dirPath);
        final stat = await entity.stat();
        final checksum = await _computeSha256(entity);

        files.add(FileEntry(
          relativePath: relativePath,
          sizeBytes: stat.size,
          sha256Checksum: checksum,
        ));
        totalBytes += stat.size;
      }
    }

    // Sort for deterministic ordering across platforms
    files.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    return TransferManifest(
      transferId: const Uuid().v4(),
      files: files,
      totalBytes: totalBytes,
      createdAt: DateTime.now(),
    );
  }

  /// Streams [FileChunk]s for a single file.
  ///
  /// If [startOffset] is provided, chunks before that offset are skipped
  /// (used for resuming an interrupted transfer).
  Stream<FileChunk> chunkFile(
    String filePath, {
    required int fileIndex,
    int startOffset = 0,
  }) async* {
    final file = File(filePath);
    final fileLength = await file.length();

    if (fileLength == 0) {
      // Emit one empty chunk for zero-byte files so the receiver
      // knows the file exists and creates it.
      yield FileChunk(
        fileIndex: fileIndex,
        chunkIndex: 0,
        offset: 0,
        data: Uint8List(0),
      );
      return;
    }

    final raf = await file.open(mode: FileMode.read);
    try {
      int offset = startOffset;
      int chunkIndex = startOffset ~/ chunkSize;

      if (offset > 0) {
        await raf.setPosition(offset);
      }

      while (offset < fileLength) {
        final remaining = fileLength - offset;
        final readSize = remaining < chunkSize ? remaining : chunkSize;
        final data = await raf.read(readSize);

        yield FileChunk(
          fileIndex: fileIndex,
          chunkIndex: chunkIndex,
          offset: offset,
          data: Uint8List.fromList(data),
        );

        offset += data.length;
        chunkIndex++;
      }
    } finally {
      await raf.close();
    }
  }

  /// Computes the SHA-256 digest of a file using streaming (chunked)
  /// hashing — never loads the full file into memory.
  Future<String> _computeSha256(File file) async {
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);

    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();

    return output.events.single.toString();
  }

  /// Verifies that a received file matches the expected SHA-256 checksum.
  Future<bool> verifyChecksum(String filePath, String expectedChecksum) async {
    final file = File(filePath);
    if (!await file.exists()) return false;
    final actual = await _computeSha256(file);
    return actual == expectedChecksum;
  }
}
