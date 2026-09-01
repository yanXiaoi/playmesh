import 'dart:io';

import 'package:playmesh_database/playmesh_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late PlaymeshDatabase database;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'playmesh-database-test-',
    );
    database = PlaymeshDatabase(
      filePath: '${temporaryDirectory.path}${Platform.pathSeparator}_game.db',
    );
    await database.open();
    await database.execute(
      PlaymeshDatabaseOperation.update,
      'CREATE TABLE items ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'name TEXT NOT NULL'
      ') STRICT',
      const [],
    );
  });

  tearDown(() async {
    await database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('binds values without treating them as SQL', () async {
    const maliciousValue = "entry'); DROP TABLE items; --";
    final result = await database.execute(
      PlaymeshDatabaseOperation.insert,
      'INSERT INTO items (name) VALUES (?)',
      const [maliciousValue],
    );

    expect(result, {'changes': 1, 'lastInsertRowId': '1'});
    expect(
      await database.execute(
        PlaymeshDatabaseOperation.select,
        'SELECT name FROM items WHERE id = ?',
        const [1],
      ),
      [
        {'name': maliciousValue},
      ],
    );
  });

  test('supports indexed and named SQLite placeholders', () async {
    await database.execute(
      PlaymeshDatabaseOperation.insert,
      'INSERT INTO items (id, name) VALUES (?2, ?1)',
      const ['indexed', 7],
    );
    await database.execute(
      PlaymeshDatabaseOperation.insert,
      'INSERT INTO items (id, name) VALUES (:id, :name)',
      const {'id': 8, 'name': 'colon'},
    );
    await database.execute(
      PlaymeshDatabaseOperation.insert,
      'INSERT INTO items (id, name) VALUES (@id, @name)',
      const {'@id': 9, '@name': 'at'},
    );
    await database.execute(
      PlaymeshDatabaseOperation.insert,
      r'INSERT INTO items (id, name) VALUES ($id, $name)',
      const {r'$id': 10, r'$name': 'dollar'},
    );

    expect(
      await database.execute(
        PlaymeshDatabaseOperation.select,
        'SELECT id, name FROM items WHERE id >= :minimum ORDER BY id',
        const {'minimum': 7},
      ),
      [
        {'id': 7, 'name': 'indexed'},
        {'id': 8, 'name': 'colon'},
        {'id': 9, 'name': 'at'},
        {'id': 10, 'name': 'dollar'},
      ],
    );
  });

  test('gives every transaction an independent WAL connection', () async {
    final first = await database.beginTransaction();
    expect(
      await database.executeTransaction(
        first,
        PlaymeshDatabaseOperation.select,
        'SELECT COUNT(*) AS count FROM items',
        const [],
      ),
      [
        {'count': 0},
      ],
    );

    final second = await database.beginTransaction();
    await database.executeTransaction(
      second,
      PlaymeshDatabaseOperation.insert,
      'INSERT INTO items (name) VALUES (?)',
      const ['committed elsewhere'],
    );
    await database.commitTransaction(second);

    expect(
      await database.executeTransaction(
        first,
        PlaymeshDatabaseOperation.select,
        'SELECT COUNT(*) AS count FROM items',
        const [],
      ),
      [
        {'count': 0},
      ],
    );
    await database.rollbackTransaction(first);
    expect(
      await database.execute(
        PlaymeshDatabaseOperation.select,
        'SELECT COUNT(*) AS count FROM items',
        const [],
      ),
      [
        {'count': 1},
      ],
    );
  });

  test('rejects control statements and multiple statements', () async {
    await expectLater(
      database.execute(
        PlaymeshDatabaseOperation.select,
        "ATTACH DATABASE ? AS escaped",
        const ['outside.db'],
      ),
      throwsA(
        isA<PlaymeshDatabaseException>().having(
          (error) => error.code,
          'code',
          'db_operation_not_allowed',
        ),
      ),
    );
    await expectLater(
      database.execute(
        PlaymeshDatabaseOperation.insert,
        'INSERT INTO items (name) VALUES (?); DROP TABLE items',
        const ['safe'],
      ),
      throwsA(isA<PlaymeshDatabaseException>()),
    );
    await expectLater(
      database.execute(
        PlaymeshDatabaseOperation.update,
        'CREATE TRIGGER items_guard BEFORE DELETE ON items BEGIN '
        "SELECT RAISE(ABORT, 'blocked'); END",
        const [],
      ),
      throwsA(
        isA<PlaymeshDatabaseException>().having(
          (error) => error.code,
          'code',
          'db_operation_not_allowed',
        ),
      ),
    );
  });

  test('returns native table and index DDL', () async {
    await database.execute(
      PlaymeshDatabaseOperation.update,
      'CREATE INDEX items_name_index ON items(name)',
      const [],
    );

    final ddl = await database.getDdl('items') as List;
    expect(ddl, hasLength(2));
    expect(
      ddl.first,
      allOf(
        containsPair('type', 'table'),
        containsPair('name', 'items'),
        containsPair('tableName', 'items'),
        containsPair('sql', contains('CREATE TABLE items')),
      ),
    );
    expect(ddl.last, {
      'type': 'index',
      'name': 'items_name_index',
      'tableName': 'items',
      'sql': 'CREATE INDEX items_name_index ON items(name)',
    });
  });

  test('passes placeholder count failures through from sqlite3', () async {
    await expectLater(
      database.execute(
        PlaymeshDatabaseOperation.select,
        'SELECT ? AS value',
        const [],
      ),
      throwsA(
        isA<PlaymeshDatabaseException>().having(
          (error) => error.message,
          'message',
          contains('Expected 1 parameters, got 0'),
        ),
      ),
    );
  });
}
