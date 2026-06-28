import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'file_chunker.dart';

/// Persists transfer progress to SQLite so interrupted transfers can be
/// resumed from the last acknowledged byte offset.
///
/// Security notes:
/// - Only relative file paths (from the manifest) are stored — never
///   absolute device paths, preventing filesystem structure leaks.
/// - The database itself lives in the app's private storage directory
///   (via [getDatabasesPath]), not in a user-accessible location.
class ResumeStateStore {
  Database? _db;
  final String? _dbPath; // For testing — allows specifying a custom path

  ResumeStateStore({String? dbPath}) : _dbPath = dbPath;

  /// Opens (or creates) the SQLite database.
  Future<void> init() async {
    if (_db != null) return;

    final String path;
    if (_dbPath != null) {
      path = _dbPath;
    } else {
      final dbDir = await getDatabasesPath();
      path = p.join(dbDir, 'flashy_transfer_state.db');
    }

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE transfer_state (
            transfer_id   TEXT NOT NULL,
            file_index    INTEGER NOT NULL,
            last_ack_offset INTEGER NOT NULL,
            completed     INTEGER DEFAULT 0,
            PRIMARY KEY (transfer_id, file_index)
          )
        ''');

        await db.execute('''
          CREATE TABLE transfer_manifests (
            transfer_id   TEXT PRIMARY KEY,
            manifest_json TEXT NOT NULL,
            direction     TEXT NOT NULL,
            status        TEXT NOT NULL,
            created_at    TEXT NOT NULL,
            updated_at    TEXT NOT NULL
          )
        ''');
      },
    );
  }

  /// Ensures the database is initialized before use.
  Database get _database {
    if (_db == null) {
      throw StateError(
        'ResumeStateStore not initialized. Call init() first.',
      );
    }
    return _db!;
  }

  /// Persists a new transfer manifest.
  Future<void> saveManifest(
    String transferId,
    TransferManifest manifest,
    String direction,
  ) async {
    final now = DateTime.now().toIso8601String();
    await _database.insert(
      'transfer_manifests',
      {
        'transfer_id': transferId,
        'manifest_json': jsonEncode(manifest.toJson()),
        'direction': direction,
        'status': 'in_progress',
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Initialize per-file state entries
    final batch = _database.batch();
    for (var i = 0; i < manifest.files.length; i++) {
      batch.insert(
        'transfer_state',
        {
          'transfer_id': transferId,
          'file_index': i,
          'last_ack_offset': 0,
          'completed': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Updates the last acknowledged byte offset for a file in a transfer.
  ///
  /// Called on every ACK during a transfer.
  Future<void> updateProgress(
    String transferId,
    int fileIndex,
    int acknowledgedOffset,
  ) async {
    await _database.update(
      'transfer_state',
      {
        'last_ack_offset': acknowledgedOffset,
      },
      where: 'transfer_id = ? AND file_index = ?',
      whereArgs: [transferId, fileIndex],
    );

    // Touch the manifest's updated_at
    await _database.update(
      'transfer_manifests',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
  }

  /// Marks a specific file in the transfer as completed (checksum verified).
  Future<void> markFileCompleted(String transferId, int fileIndex) async {
    await _database.update(
      'transfer_state',
      {'completed': 1},
      where: 'transfer_id = ? AND file_index = ?',
      whereArgs: [transferId, fileIndex],
    );
  }

  /// Marks the entire transfer as completed.
  Future<void> markTransferCompleted(String transferId) async {
    await _database.update(
      'transfer_manifests',
      {
        'status': 'completed',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
  }

  /// Marks the entire transfer as failed.
  Future<void> markTransferFailed(String transferId) async {
    await _database.update(
      'transfer_manifests',
      {
        'status': 'failed',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
  }

  /// Returns the last acknowledged byte offset for a file in a transfer,
  /// or `null` if no progress has been recorded.
  Future<int?> getResumeOffset(String transferId, int fileIndex) async {
    final rows = await _database.query(
      'transfer_state',
      columns: ['last_ack_offset'],
      where: 'transfer_id = ? AND file_index = ? AND completed = 0',
      whereArgs: [transferId, fileIndex],
    );

    if (rows.isEmpty) return null;
    final offset = rows.first['last_ack_offset'] as int;
    return offset > 0 ? offset : null;
  }

  /// Returns manifests for all incomplete (in-progress) transfers.
  Future<List<TransferManifest>> getIncompleteTransfers() async {
    final rows = await _database.query(
      'transfer_manifests',
      where: 'status = ?',
      whereArgs: ['in_progress'],
      orderBy: 'updated_at DESC',
    );

    return rows.map((row) {
      final json = jsonDecode(row['manifest_json'] as String);
      return TransferManifest.fromJson(json as Map<String, dynamic>);
    }).toList();
  }

  /// Returns the manifest for a specific transfer, or `null` if not found.
  Future<TransferManifest?> getManifest(String transferId) async {
    final rows = await _database.query(
      'transfer_manifests',
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );

    if (rows.isEmpty) return null;
    final json = jsonDecode(rows.first['manifest_json'] as String);
    return TransferManifest.fromJson(json as Map<String, dynamic>);
  }

  /// Deletes all state for a completed transfer (cleanup).
  Future<void> deleteTransferState(String transferId) async {
    final batch = _database.batch();
    batch.delete(
      'transfer_state',
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
    batch.delete(
      'transfer_manifests',
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
    await batch.commit(noResult: true);
  }

  /// Closes the database connection.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
