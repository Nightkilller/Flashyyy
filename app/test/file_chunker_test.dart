import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flashy/core/transfer/file_chunker.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flashy_chunker_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('FileChunker — single file', () {
    test('generates correct manifest for a small text file', () async {
      final file = File('${tempDir.path}/hello.txt');
      await file.writeAsString('Hello, Flashy!');

      const chunker = FileChunker();
      final manifest = await chunker.generateManifestForFile(file.path);

      expect(manifest.files.length, 1);
      expect(manifest.files[0].relativePath, 'hello.txt');
      expect(manifest.files[0].sizeBytes, 14); // "Hello, Flashy!" = 14 bytes
      expect(manifest.transferId, isNotEmpty);
      expect(manifest.totalBytes, 14);
    });

    test('SHA-256 checksum matches manually computed hash', () async {
      final content = 'Flashy transfer engine test content';
      final file = File('${tempDir.path}/checksum_test.txt');
      await file.writeAsString(content);

      const chunker = FileChunker();
      final manifest = await chunker.generateManifestForFile(file.path);

      // Compute expected hash manually
      final expectedHash = sha256.convert(content.codeUnits).toString();
      expect(manifest.files[0].sha256Checksum, expectedHash);
    });

    test('chunks a file into correct-sized pieces', () async {
      // Create a 2.5 chunk-size file (with chunk size = 1024 for test speed)
      const testChunkSize = 1024;
      final data = Uint8List(testChunkSize * 2 + 512); // 2560 bytes
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      final file = File('${tempDir.path}/chunked.bin');
      await file.writeAsBytes(data);

      const chunker = FileChunker(chunkSize: testChunkSize);
      final chunks = await chunker
          .chunkFile(file.path, fileIndex: 0)
          .toList();

      expect(chunks.length, 3);

      // First two chunks should be full size
      expect(chunks[0].length, testChunkSize);
      expect(chunks[0].offset, 0);
      expect(chunks[0].chunkIndex, 0);

      expect(chunks[1].length, testChunkSize);
      expect(chunks[1].offset, testChunkSize);
      expect(chunks[1].chunkIndex, 1);

      // Last chunk should be the remainder
      expect(chunks[2].length, 512);
      expect(chunks[2].offset, testChunkSize * 2);
      expect(chunks[2].chunkIndex, 2);

      // Verify all bytes are correct
      final reassembled = BytesBuilder();
      for (final chunk in chunks) {
        reassembled.add(chunk.data);
      }
      expect(reassembled.toBytes(), data);
    });

    test('handles zero-byte files', () async {
      final file = File('${tempDir.path}/empty.txt');
      await file.create();

      const chunker = FileChunker();
      final manifest = await chunker.generateManifestForFile(file.path);

      expect(manifest.files[0].sizeBytes, 0);
      expect(manifest.totalBytes, 0);

      final chunks = await chunker
          .chunkFile(file.path, fileIndex: 0)
          .toList();

      // Should emit exactly one empty chunk
      expect(chunks.length, 1);
      expect(chunks[0].data.length, 0);
      expect(chunks[0].offset, 0);
    });

    test('chunks with startOffset skip leading chunks', () async {
      const testChunkSize = 100;
      final data = Uint8List(350);
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      final file = File('${tempDir.path}/resume.bin');
      await file.writeAsBytes(data);

      const chunker = FileChunker(chunkSize: testChunkSize);
      final chunks = await chunker
          .chunkFile(file.path, fileIndex: 0, startOffset: 200)
          .toList();

      // Should skip first 2 chunks (0-99, 100-199), emit 2 more (200-299, 300-349)
      expect(chunks.length, 2);
      expect(chunks[0].offset, 200);
      expect(chunks[0].chunkIndex, 2);
      expect(chunks[0].length, 100);
      expect(chunks[1].offset, 300);
      expect(chunks[1].chunkIndex, 3);
      expect(chunks[1].length, 50);
    });

    test('throws on non-existent file', () async {
      const chunker = FileChunker();
      expect(
        () => chunker.generateManifestForFile('${tempDir.path}/nope.txt'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('FileChunker — directory', () {
    test('generates manifest for a directory tree', () async {
      // Create nested structure:
      // testdir/
      //   file_a.txt
      //   sub/
      //     file_b.txt
      //     deep/
      //       file_c.txt
      await Directory('${tempDir.path}/testdir/sub/deep')
          .create(recursive: true);

      await File('${tempDir.path}/testdir/file_a.txt')
          .writeAsString('File A content');
      await File('${tempDir.path}/testdir/sub/file_b.txt')
          .writeAsString('File B');
      await File('${tempDir.path}/testdir/sub/deep/file_c.txt')
          .writeAsString('Deep file C data!');

      const chunker = FileChunker();
      final manifest = await chunker.generateManifestForDirectory(
        '${tempDir.path}/testdir',
      );

      expect(manifest.files.length, 3);
      expect(manifest.totalBytes, greaterThan(0));

      // Files should be sorted by relative path
      final paths = manifest.files.map((f) => f.relativePath).toList();
      expect(paths, equals(List.from(paths)..sort()));

      // Check that paths are relative (no absolute paths — security)
      for (final entry in manifest.files) {
        expect(entry.relativePath, isNot(startsWith('/')));
        expect(entry.relativePath, isNot(contains(tempDir.path)));
        expect(entry.sizeBytes, greaterThan(0));
        expect(entry.sha256Checksum, isNotEmpty);
      }
    });

    test('handles empty directory', () async {
      await Directory('${tempDir.path}/emptydir').create();

      const chunker = FileChunker();
      final manifest = await chunker.generateManifestForDirectory(
        '${tempDir.path}/emptydir',
      );

      expect(manifest.files, isEmpty);
      expect(manifest.totalBytes, 0);
    });

    test('throws on non-existent directory', () async {
      const chunker = FileChunker();
      expect(
        () => chunker.generateManifestForDirectory('${tempDir.path}/nope'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('FileChunker — checksum verification', () {
    test('verifyChecksum returns true for matching file', () async {
      final content = 'Verify me!';
      final file = File('${tempDir.path}/verify.txt');
      await file.writeAsString(content);

      const chunker = FileChunker();
      final manifest = await chunker.generateManifestForFile(file.path);
      final checksum = manifest.files[0].sha256Checksum;

      expect(await chunker.verifyChecksum(file.path, checksum), isTrue);
    });

    test('verifyChecksum returns false for tampered file', () async {
      final file = File('${tempDir.path}/tamper.txt');
      await file.writeAsString('Original');

      const chunker = FileChunker();
      final manifest = await chunker.generateManifestForFile(file.path);
      final checksum = manifest.files[0].sha256Checksum;

      // Tamper with the file
      await file.writeAsString('Tampered!');

      expect(await chunker.verifyChecksum(file.path, checksum), isFalse);
    });

    test('verifyChecksum returns false for non-existent file', () async {
      const chunker = FileChunker();
      expect(
        await chunker.verifyChecksum('${tempDir.path}/gone.txt', 'abc'),
        isFalse,
      );
    });
  });

  group('TransferManifest — serialization', () {
    test('roundtrips through JSON correctly', () async {
      final file = File('${tempDir.path}/serial.txt');
      await file.writeAsString('Serialization test');

      const chunker = FileChunker();
      final original = await chunker.generateManifestForFile(file.path);

      final json = original.toJson();
      final restored = TransferManifest.fromJson(json);

      expect(restored.transferId, original.transferId);
      expect(restored.totalBytes, original.totalBytes);
      expect(restored.files.length, original.files.length);
      expect(
        restored.files[0].relativePath,
        original.files[0].relativePath,
      );
      expect(
        restored.files[0].sha256Checksum,
        original.files[0].sha256Checksum,
      );
      expect(restored.files[0].sizeBytes, original.files[0].sizeBytes);
    });
  });

  group('FileChunker — large file streaming', () {
    test('handles large file without loading into memory', () async {
      // Create a 5MB file
      final file = File('${tempDir.path}/large.bin');
      final random = Random(42);
      const size = 5 * 1024 * 1024; // 5MB

      final sink = file.openWrite();
      var written = 0;
      while (written < size) {
        final chunkSize = min(65536, size - written);
        final bytes = Uint8List(chunkSize);
        for (var i = 0; i < chunkSize; i++) {
          bytes[i] = random.nextInt(256);
        }
        sink.add(bytes);
        written += chunkSize;
      }
      await sink.close();

      const chunker = FileChunker();
      final manifest = await chunker.generateManifestForFile(file.path);

      expect(manifest.files[0].sizeBytes, size);
      expect(manifest.files[0].sha256Checksum, isNotEmpty);

      // Verify we can chunk it
      var totalChunked = 0;
      await for (final chunk in chunker.chunkFile(file.path, fileIndex: 0)) {
        totalChunked += chunk.length;
      }
      expect(totalChunked, size);
    });
  });
}
