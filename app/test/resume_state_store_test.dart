import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flashy/core/transfer/file_chunker.dart';
import 'package:flashy/core/transfer/resume_state_store.dart';

void main() {
  late ResumeStateStore store;
  late Directory tempDir;

  setUpAll(() {
    // Use FFI-based sqflite for desktop tests
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flashy_resume_test_');
    store = ResumeStateStore(dbPath: '${tempDir.path}/test_resume.db');
    await store.init();
  });

  tearDown(() async {
    await store.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ResumeStateStore — basic operations', () {
    test('saves and retrieves a manifest', () async {
      final manifest = _createTestManifest('test-001', 3);

      await store.saveManifest('test-001', manifest, 'send');

      final retrieved = await store.getManifest('test-001');
      expect(retrieved, isNotNull);
      expect(retrieved!.transferId, 'test-001');
      expect(retrieved.files.length, 3);
    });

    test('returns null for non-existent manifest', () async {
      final result = await store.getManifest('nonexistent');
      expect(result, isNull);
    });

    test('updates and retrieves progress correctly', () async {
      final manifest = _createTestManifest('test-002', 2);
      await store.saveManifest('test-002', manifest, 'send');

      // Update progress for file 0
      await store.updateProgress('test-002', 0, 512000);

      final offset = await store.getResumeOffset('test-002', 0);
      expect(offset, 512000);
    });

    test('getResumeOffset returns null when no progress', () async {
      final manifest = _createTestManifest('test-003', 1);
      await store.saveManifest('test-003', manifest, 'send');

      // No progress updated yet — offset should be null
      final offset = await store.getResumeOffset('test-003', 0);
      expect(offset, isNull);
    });

    test('getResumeOffset returns null for completed files', () async {
      final manifest = _createTestManifest('test-004', 1);
      await store.saveManifest('test-004', manifest, 'send');

      await store.updateProgress('test-004', 0, 1024);
      await store.markFileCompleted('test-004', 0);

      // Completed files should not appear as resumable
      final offset = await store.getResumeOffset('test-004', 0);
      expect(offset, isNull);
    });
  });

  group('ResumeStateStore — transfer lifecycle', () {
    test('tracks incomplete transfers', () async {
      final m1 = _createTestManifest('inc-001', 1);
      final m2 = _createTestManifest('inc-002', 1);
      final m3 = _createTestManifest('inc-003', 1);

      await store.saveManifest('inc-001', m1, 'send');
      await store.saveManifest('inc-002', m2, 'receive');
      await store.saveManifest('inc-003', m3, 'send');

      // Complete one
      await store.markTransferCompleted('inc-002');

      final incomplete = await store.getIncompleteTransfers();
      expect(incomplete.length, 2);
      expect(
        incomplete.map((m) => m.transferId).toSet(),
        {'inc-001', 'inc-003'},
      );
    });

    test('markTransferCompleted changes status', () async {
      final manifest = _createTestManifest('comp-001', 1);
      await store.saveManifest('comp-001', manifest, 'send');
      await store.markTransferCompleted('comp-001');

      final incomplete = await store.getIncompleteTransfers();
      expect(incomplete.where((m) => m.transferId == 'comp-001'), isEmpty);
    });

    test('markTransferFailed changes status', () async {
      final manifest = _createTestManifest('fail-001', 1);
      await store.saveManifest('fail-001', manifest, 'send');
      await store.markTransferFailed('fail-001');

      final incomplete = await store.getIncompleteTransfers();
      expect(incomplete.where((m) => m.transferId == 'fail-001'), isEmpty);
    });

    test('deleteTransferState cleans up everything', () async {
      final manifest = _createTestManifest('del-001', 2);
      await store.saveManifest('del-001', manifest, 'send');
      await store.updateProgress('del-001', 0, 1024);
      await store.updateProgress('del-001', 1, 2048);

      await store.deleteTransferState('del-001');

      expect(await store.getManifest('del-001'), isNull);
      expect(await store.getResumeOffset('del-001', 0), isNull);
      expect(await store.getResumeOffset('del-001', 1), isNull);
    });
  });

  group('ResumeStateStore — progressive updates', () {
    test('tracks incremental progress across multiple updates', () async {
      final manifest = _createTestManifest('prog-001', 1);
      await store.saveManifest('prog-001', manifest, 'send');

      // Simulate receiving ACKs in sequence
      await store.updateProgress('prog-001', 0, 512 * 1024);
      expect(await store.getResumeOffset('prog-001', 0), 512 * 1024);

      await store.updateProgress('prog-001', 0, 1024 * 1024);
      expect(await store.getResumeOffset('prog-001', 0), 1024 * 1024);

      await store.updateProgress('prog-001', 0, 1536 * 1024);
      expect(await store.getResumeOffset('prog-001', 0), 1536 * 1024);
    });

    test('tracks multiple files independently', () async {
      final manifest = _createTestManifest('multi-001', 3);
      await store.saveManifest('multi-001', manifest, 'receive');

      await store.updateProgress('multi-001', 0, 100);
      await store.updateProgress('multi-001', 1, 200);
      await store.updateProgress('multi-001', 2, 300);

      expect(await store.getResumeOffset('multi-001', 0), 100);
      expect(await store.getResumeOffset('multi-001', 1), 200);
      expect(await store.getResumeOffset('multi-001', 2), 300);
    });
  });
}

/// Creates a test manifest with the given number of files.
TransferManifest _createTestManifest(String transferId, int fileCount) {
  final files = List.generate(fileCount, (i) {
    return FileEntry(
      relativePath: 'test_file_$i.dat',
      sizeBytes: (i + 1) * 1024 * 1024, // 1MB, 2MB, 3MB, ...
      sha256Checksum: 'fakechecksum_$i',
    );
  });

  return TransferManifest(
    transferId: transferId,
    files: files,
    totalBytes: files.fold(0, (sum, f) => sum + f.sizeBytes),
    createdAt: DateTime.now(),
  );
}
