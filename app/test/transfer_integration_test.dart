import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flashy/core/transfer/file_chunker.dart';
import 'package:flashy/core/transfer/transfer_manager.dart';
import 'package:flashy/core/transfer/resume_state_store.dart';
import 'package:flashy/core/transport/connection.dart';
import 'package:flashy/core/transport/localhost_connection.dart';

void main() {
  late Directory tempDir;
  late Directory sendDir;
  late Directory receiveDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flashy_integration_');
    sendDir = Directory('${tempDir.path}/send');
    receiveDir = Directory('${tempDir.path}/receive');
    await sendDir.create();
    await receiveDir.create();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Integration — single file transfer', () {
    test('transfers a small text file with correct checksum', () async {
      // Create source file
      final sourceFile = File('${sendDir.path}/hello.txt');
      await sourceFile.writeAsString('Hello from Flashy! 🚀');

      // Set up stores
      final senderStore = ResumeStateStore(
        dbPath: '${tempDir.path}/sender.db',
      );
      final receiverStore = ResumeStateStore(
        dbPath: '${tempDir.path}/receiver.db',
      );
      await senderStore.init();
      await receiverStore.init();

      // Set up localhost connection
      final server = await LocalhostServer.start();
      final clientConn = await LocalhostClient.connect(
        '127.0.0.1',
        server.port,
      );
      final serverConn = await server.acceptConnection();

      // Run sender and receiver concurrently
      final senderManager = TransferManager(resumeStore: senderStore);
      final receiverManager = TransferManager(resumeStore: receiverStore);

      final results = await Future.wait([
        senderManager.sendFile(clientConn, sourceFile.path),
        receiverManager.receiveFiles(serverConn, receiveDir.path),
      ]);

      expect(results[0].success, isTrue, reason: 'Sender reported failure: ${results[0].errorMessage}');
      expect(results[1].success, isTrue, reason: 'Receiver reported failure: ${results[1].errorMessage}');

      // Verify file exists and content matches
      final receivedFile = File('${receiveDir.path}/hello.txt');
      expect(await receivedFile.exists(), isTrue);
      expect(
        await receivedFile.readAsString(),
        'Hello from Flashy! 🚀',
      );

      // Cleanup
      await clientConn.close();
      await serverConn.close();
      await server.stop();
      await senderStore.close();
      await receiverStore.close();
    });

    test('transfers a binary file with verified SHA-256', () async {
      // Create a 2MB binary file with random data
      final random = Random(12345);
      final data = Uint8List(2 * 1024 * 1024);
      for (var i = 0; i < data.length; i++) {
        data[i] = random.nextInt(256);
      }

      final sourceFile = File('${sendDir.path}/binary.dat');
      await sourceFile.writeAsBytes(data);

      final expectedHash = sha256.convert(data).toString();

      final senderStore = ResumeStateStore(
        dbPath: '${tempDir.path}/sender_bin.db',
      );
      final receiverStore = ResumeStateStore(
        dbPath: '${tempDir.path}/receiver_bin.db',
      );
      await senderStore.init();
      await receiverStore.init();

      final server = await LocalhostServer.start();
      final clientConn = await LocalhostClient.connect(
        '127.0.0.1',
        server.port,
      );
      final serverConn = await server.acceptConnection();

      final senderManager = TransferManager(resumeStore: senderStore);
      final receiverManager = TransferManager(resumeStore: receiverStore);

      final results = await Future.wait([
        senderManager.sendFile(clientConn, sourceFile.path),
        receiverManager.receiveFiles(serverConn, receiveDir.path),
      ]);

      expect(results[0].success, isTrue, reason: 'Send failed: ${results[0].errorMessage}');
      expect(results[1].success, isTrue, reason: 'Receive failed: ${results[1].errorMessage}');

      // Verify SHA-256
      final receivedFile = File('${receiveDir.path}/binary.dat');
      final receivedData = await receivedFile.readAsBytes();
      final receivedHash = sha256.convert(receivedData).toString();
      expect(receivedHash, expectedHash);

      await clientConn.close();
      await serverConn.close();
      await server.stop();
      await senderStore.close();
      await receiverStore.close();
    });

    test('transfers a zero-byte file correctly', () async {
      final sourceFile = File('${sendDir.path}/empty.txt');
      await sourceFile.create();

      final senderStore = ResumeStateStore(
        dbPath: '${tempDir.path}/sender_empty.db',
      );
      final receiverStore = ResumeStateStore(
        dbPath: '${tempDir.path}/receiver_empty.db',
      );
      await senderStore.init();
      await receiverStore.init();

      final server = await LocalhostServer.start();
      final clientConn = await LocalhostClient.connect(
        '127.0.0.1',
        server.port,
      );
      final serverConn = await server.acceptConnection();

      final results = await Future.wait([
        TransferManager(resumeStore: senderStore)
            .sendFile(clientConn, sourceFile.path),
        TransferManager(resumeStore: receiverStore)
            .receiveFiles(serverConn, receiveDir.path),
      ]);

      expect(results[0].success, isTrue);
      expect(results[1].success, isTrue);

      final receivedFile = File('${receiveDir.path}/empty.txt');
      expect(await receivedFile.exists(), isTrue);
      expect(await receivedFile.length(), 0);

      await clientConn.close();
      await serverConn.close();
      await server.stop();
      await senderStore.close();
      await receiverStore.close();
    });
  });

  group('Integration — directory transfer', () {
    test('transfers a nested directory structure', () async {
      // Create nested structure
      await Directory('${sendDir.path}/project/src/utils')
          .create(recursive: true);
      await Directory('${sendDir.path}/project/assets')
          .create(recursive: true);

      await File('${sendDir.path}/project/README.md')
          .writeAsString('# My Project');
      await File('${sendDir.path}/project/src/main.dart')
          .writeAsString('void main() {}');
      await File('${sendDir.path}/project/src/utils/helpers.dart')
          .writeAsString('String greet() => "hi";');
      await File('${sendDir.path}/project/assets/icon.txt')
          .writeAsString('ICON_DATA_PLACEHOLDER');

      final senderStore = ResumeStateStore(
        dbPath: '${tempDir.path}/sender_dir.db',
      );
      final receiverStore = ResumeStateStore(
        dbPath: '${tempDir.path}/receiver_dir.db',
      );
      await senderStore.init();
      await receiverStore.init();

      final server = await LocalhostServer.start();
      final clientConn = await LocalhostClient.connect(
        '127.0.0.1',
        server.port,
      );
      final serverConn = await server.acceptConnection();

      final results = await Future.wait([
        TransferManager(resumeStore: senderStore)
            .sendDirectory(clientConn, '${sendDir.path}/project'),
        TransferManager(resumeStore: receiverStore)
            .receiveFiles(serverConn, receiveDir.path),
      ]);

      expect(results[0].success, isTrue, reason: 'Send failed: ${results[0].errorMessage}');
      expect(results[1].success, isTrue, reason: 'Receive failed: ${results[1].errorMessage}');

      // Verify directory structure is preserved
      expect(
        await File('${receiveDir.path}/README.md').readAsString(),
        '# My Project',
      );
      expect(
        await File('${receiveDir.path}/src/main.dart').readAsString(),
        'void main() {}',
      );
      expect(
        await File('${receiveDir.path}/src/utils/helpers.dart').readAsString(),
        'String greet() => "hi";',
      );
      expect(
        await File('${receiveDir.path}/assets/icon.txt').readAsString(),
        'ICON_DATA_PLACEHOLDER',
      );

      await clientConn.close();
      await serverConn.close();
      await server.stop();
      await senderStore.close();
      await receiverStore.close();
    });
  });

  group('Integration — progress reporting', () {
    test('reports progress during transfer', () async {
      // Create a file large enough to produce multiple chunks
      final data = Uint8List(1024 * 1024); // 1MB
      for (var i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }
      final sourceFile = File('${sendDir.path}/progress.dat');
      await sourceFile.writeAsBytes(data);

      final senderStore = ResumeStateStore(
        dbPath: '${tempDir.path}/sender_prog.db',
      );
      final receiverStore = ResumeStateStore(
        dbPath: '${tempDir.path}/receiver_prog.db',
      );
      await senderStore.init();
      await receiverStore.init();

      final server = await LocalhostServer.start();
      final clientConn = await LocalhostClient.connect(
        '127.0.0.1',
        server.port,
      );
      final serverConn = await server.acceptConnection();

      final senderProgress = <TransferProgress>[];
      final receiverProgress = <TransferProgress>[];

      final results = await Future.wait([
        TransferManager(resumeStore: senderStore).sendFile(
          clientConn,
          sourceFile.path,
          onProgress: (p) => senderProgress.add(p),
        ),
        TransferManager(resumeStore: receiverStore).receiveFiles(
          serverConn,
          receiveDir.path,
          onProgress: (p) => receiverProgress.add(p),
        ),
      ]);

      expect(results[0].success, isTrue);
      expect(results[1].success, isTrue);

      // Should have multiple progress updates (1MB / 512KB = 2 chunks)
      expect(senderProgress, isNotEmpty);
      expect(receiverProgress, isNotEmpty);

      // Final progress should show 100%
      expect(senderProgress.last.transferredBytes, data.length);
      expect(senderProgress.last.fraction, closeTo(1.0, 0.01));

      await clientConn.close();
      await serverConn.close();
      await server.stop();
      await senderStore.close();
      await receiverStore.close();
    });
  });
}
