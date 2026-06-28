import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Database management for local non-secure application data (contacts, paired devices).
class LocalDatabase {
  Database? _db;
  final String? _dbPath; // For testing injection

  LocalDatabase({String? dbPath}) : _dbPath = dbPath;

  /// Opens or creates the SQLite database.
  Future<void> init() async {
    if (_db != null) return;

    final String path;
    if (_dbPath != null) {
      path = _dbPath;
    } else {
      final dbDir = await getDatabasesPath();
      path = p.join(dbDir, 'flashy_local.db');
    }

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE contacts (
            device_id    TEXT PRIMARY KEY,
            device_name  TEXT NOT NULL,
            public_key   TEXT NOT NULL,
            paired_at    TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Database get _database {
    if (_db == null) {
      throw StateError('LocalDatabase not initialized. Call init() first.');
    }
    return _db!;
  }

  /// Adds a new contact/paired device to the database.
  Future<void> addContact({
    required String deviceId,
    required String deviceName,
    required String publicKey,
  }) async {
    final now = DateTime.now().toIso8601String();
    await _database.insert(
      'contacts',
      {
        'device_id': deviceId,
        'device_name': deviceName,
        'public_key': publicKey,
        'paired_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Retrieves all paired contacts.
  Future<List<Map<String, dynamic>>> getContacts() async {
    return await _database.query('contacts', orderBy: 'device_name ASC');
  }

  /// Checks if a device is paired.
  Future<bool> isContactPaired(String deviceId) async {
    final rows = await _database.query(
      'contacts',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    return rows.isNotEmpty;
  }

  /// Removes a contact/unpairs a device.
  Future<void> deleteContact(String deviceId) async {
    await _database.delete(
      'contacts',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  /// Closes database connection.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
