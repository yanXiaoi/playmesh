import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

enum PlaymeshDatabaseOperation { select, update, delete, insert }

final class PlaymeshDatabaseException implements Exception {
  const PlaymeshDatabaseException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// A native SQLite database whose connections are each confined to one
/// background isolate. Autocommit calls use a small connection pool and every
/// explicit transaction owns a separate connection until commit or rollback.
final class PlaymeshDatabase {
  PlaymeshDatabase({required this.filePath});

  static const int busyTimeoutMilliseconds = 5000;
  static const _ddlSql =
      'SELECT type, name, tbl_name AS tableName, sql '
      'FROM sqlite_schema '
      "WHERE type IN ('table', 'index') AND sql IS NOT NULL "
      "AND name NOT GLOB 'sqlite_*' "
      'AND (? IS NULL OR name = ? OR tbl_name = ?) '
      'ORDER BY CASE type WHEN \'table\' THEN 0 ELSE 1 END, name';

  final String filePath;
  final List<_DatabaseWorker> _pool = [];
  final Map<String, _DatabaseWorker> _transactions = {};
  Future<void>? _openOperation;
  bool _opened = false;
  bool _closed = false;
  int _poolSequence = 0;
  int _transactionSequence = 0;

  bool get isOpen => _opened && !_closed;

  Future<void> open() {
    if (_closed) {
      throw const PlaymeshDatabaseException('db_closed', '数据库已经关闭');
    }
    if (_opened) return Future<void>.value();
    return _openOperation ??= _open();
  }

  Future<void> _open() async {
    try {
      final databaseFilePath = filePath;
      await File(databaseFilePath).parent.create(recursive: true);
      await Isolate.run(() => _initializeDatabase(databaseFilePath));
      final workerCount = min(max(Platform.numberOfProcessors, 2), 4);
      final workers = await Future.wait([
        for (var index = 0; index < workerCount; index += 1)
          _DatabaseWorker.start(filePath, transaction: false),
      ]);
      _pool.addAll(workers);
      _opened = true;
    } on Object catch (error) {
      _openOperation = null;
      if (error is PlaymeshDatabaseException) rethrow;
      throw _translateDatabaseError(error);
    }
  }

  Future<Object?> execute(
    PlaymeshDatabaseOperation operation,
    String sql,
    Object arguments,
  ) async {
    _ensureOpen();
    final worker = _pool[_poolSequence++ % _pool.length];
    return worker.call(operation.name, sql: sql, arguments: arguments);
  }

  Future<Object?> getDdl([String? name]) => execute(
    PlaymeshDatabaseOperation.select,
    _ddlSql,
    <Object?>[name, name, name],
  );

  Future<String> beginTransaction() async {
    _ensureOpen();
    final transactionId =
        'tx-${DateTime.now().microsecondsSinceEpoch}-${++_transactionSequence}';
    final worker = await _DatabaseWorker.start(filePath, transaction: true);
    _transactions[transactionId] = worker;
    return transactionId;
  }

  Future<Object?> executeTransaction(
    String transactionId,
    PlaymeshDatabaseOperation operation,
    String sql,
    Object arguments,
  ) {
    _ensureOpen();
    return _transaction(
      transactionId,
    ).call(operation.name, sql: sql, arguments: arguments);
  }

  Future<Object?> getTransactionDdl(String transactionId, [String? name]) =>
      executeTransaction(
        transactionId,
        PlaymeshDatabaseOperation.select,
        _ddlSql,
        <Object?>[name, name, name],
      );

  Future<void> commitTransaction(String transactionId) async {
    _ensureOpen();
    final worker = _transaction(transactionId);
    await worker.call('commit');
    _transactions.remove(transactionId);
  }

  Future<void> rollbackTransaction(String transactionId) async {
    _ensureOpen();
    final worker = _transaction(transactionId);
    await worker.call('rollback');
    _transactions.remove(transactionId);
  }

  Future<void> rollbackAllTransactions() async {
    if (!_opened || _transactions.isEmpty) return;
    final entries = _transactions.entries.toList(growable: false);
    _transactions.clear();
    await Future.wait(
      entries.map((entry) async {
        try {
          await entry.value.call('rollback');
        } on Object {
          entry.value.terminate();
        }
      }),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await rollbackAllTransactions();
    final workers = _pool.toList(growable: false);
    _pool.clear();
    await Future.wait(
      workers.map((worker) async {
        try {
          await worker.call('close');
        } on Object {
          worker.terminate();
        }
      }),
    );
    _opened = false;
  }

  _DatabaseWorker _transaction(String transactionId) {
    final worker = _transactions[transactionId];
    if (worker == null) {
      throw const PlaymeshDatabaseException(
        'db_transaction_closed',
        '事务不存在或已经结束',
      );
    }
    return worker;
  }

  void _ensureOpen() {
    if (_closed) {
      throw const PlaymeshDatabaseException('db_closed', '数据库已经关闭');
    }
    if (!_opened) {
      throw const PlaymeshDatabaseException('db_not_open', '请先调用 db.open()');
    }
  }
}

final class _DatabaseWorker {
  _DatabaseWorker(this._isolate, this._commands);

  final Isolate _isolate;
  final SendPort _commands;
  bool _terminated = false;

  static Future<_DatabaseWorker> start(
    String filePath, {
    required bool transaction,
  }) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_connectionWorkerMain, {
      'filePath': filePath,
      'transaction': transaction,
      'ready': ready.sendPort,
    });
    try {
      final response = await ready.first;
      if (response is Map && response['ok'] == true) {
        final commands = response['commands'];
        if (commands is SendPort) return _DatabaseWorker(isolate, commands);
      }
      isolate.kill(priority: Isolate.immediate);
      throw _errorFromWorkerResponse(response);
    } finally {
      ready.close();
    }
  }

  Future<Object?> call(
    String operation, {
    String? sql,
    Object? arguments,
  }) async {
    if (_terminated) {
      throw const PlaymeshDatabaseException(
        'db_connection_closed',
        '数据库连接已经关闭',
      );
    }
    final reply = ReceivePort();
    _commands.send({
      'operation': operation,
      'sql': ?sql,
      'arguments': ?arguments,
      'reply': reply.sendPort,
    });
    try {
      final response = await reply.first;
      if (response is Map && response['ok'] == true) {
        if (operation == 'commit' ||
            operation == 'rollback' ||
            operation == 'close') {
          _terminated = true;
        }
        return response['result'];
      }
      throw _errorFromWorkerResponse(response);
    } finally {
      reply.close();
    }
  }

  void terminate() {
    if (_terminated) return;
    _terminated = true;
    _isolate.kill(priority: Isolate.immediate);
  }
}

void _initializeDatabase(String filePath) {
  final database = sqlite3.open(filePath, mutex: false);
  try {
    database.execute('PRAGMA journal_mode = WAL');
    _configureConnection(database);
  } finally {
    database.close();
  }
}

void _connectionWorkerMain(Map<Object?, Object?> bootstrap) async {
  final ready = bootstrap['ready']! as SendPort;
  final filePath = bootstrap['filePath']! as String;
  final transaction = bootstrap['transaction']! as bool;
  Database? database;
  ReceivePort? commands;
  try {
    database = sqlite3.open(filePath, mutex: false);
    _configureConnection(database);
    if (transaction) database.execute('BEGIN DEFERRED TRANSACTION');
    commands = ReceivePort();
    ready.send({'ok': true, 'commands': commands.sendPort});
    await for (final raw in commands) {
      if (raw is! Map) continue;
      final activeDatabase = database;
      if (activeDatabase == null) return;
      final reply = raw['reply'];
      if (reply is! SendPort) continue;
      final operation = raw['operation'];
      try {
        if (operation == 'commit' ||
            operation == 'rollback' ||
            operation == 'close') {
          if (operation == 'commit') {
            if (!transaction || activeDatabase.autocommit) {
              throw const PlaymeshDatabaseException(
                'db_transaction_closed',
                '事务已经结束',
              );
            }
            activeDatabase.execute('COMMIT');
          } else if (operation == 'rollback' &&
              transaction &&
              !activeDatabase.autocommit) {
            activeDatabase.execute('ROLLBACK');
          } else if (operation == 'close' &&
              transaction &&
              !activeDatabase.autocommit) {
            activeDatabase.execute('ROLLBACK');
          }
          activeDatabase.close();
          database = null;
          reply.send({'ok': true});
          commands.close();
          return;
        }
        if (operation is! String ||
            raw['sql'] is! String ||
            (raw['arguments'] is! List && raw['arguments'] is! Map)) {
          throw const PlaymeshDatabaseException(
            'db_request_invalid',
            '数据库请求无效',
          );
        }
        final result = _executeStatement(
          activeDatabase,
          operation,
          raw['sql']! as String,
          raw['arguments']! as Object,
        );
        reply.send({'ok': true, 'result': result});
      } on Object catch (error) {
        reply.send(_workerErrorResponse(error));
      }
    }
  } on Object catch (error) {
    ready.send(_workerErrorResponse(error));
  } finally {
    if (database != null) {
      try {
        if (transaction && !database.autocommit) {
          database.execute('ROLLBACK');
        }
      } on Object {
        // The connection is closing; rollback is best-effort here.
      }
      database.close();
    }
    commands?.close();
  }
}

void _configureConnection(Database database) {
  database.config.doubleQuotedStringLiterals = false;
  database.execute('PRAGMA foreign_keys = ON');
  database.execute(
    'PRAGMA busy_timeout = ${PlaymeshDatabase.busyTimeoutMilliseconds}',
  );
  database.execute('PRAGMA synchronous = FULL');
  database.execute('PRAGMA trusted_schema = OFF');
  database.execute('PRAGMA writable_schema = OFF');
}

Object? _executeStatement(
  Database database,
  String operationName,
  String sql,
  Object arguments,
) {
  final operation = PlaymeshDatabaseOperation.values
      .where((value) => value.name == operationName)
      .firstOrNull;
  if (operation == null) {
    throw const PlaymeshDatabaseException('db_request_invalid', '未知数据库操作');
  }
  final normalizedArguments = _statementParameters(arguments);
  PreparedStatement? statement;
  try {
    statement = database.prepare(
      sql,
      persistent: true,
      vtab: false,
      checkNoTail: true,
    );
    final tokens = _statementTokens(sql);
    if (statement.isExplain ||
        !_isAllowedTableStatement(statement.isReadOnly, tokens)) {
      throw const PlaymeshDatabaseException(
        'db_operation_not_allowed',
        'SQL 不在表结构与表数据操作白名单中',
      );
    }
    switch (operation) {
      case PlaymeshDatabaseOperation.select:
        if (!statement.isReadOnly) {
          throw const PlaymeshDatabaseException(
            'db_operation_not_allowed',
            'db.select() 只能执行只读查询',
          );
        }
        return _select(statement, normalizedArguments);
      case PlaymeshDatabaseOperation.insert:
        if (statement.isReadOnly) {
          throw const PlaymeshDatabaseException(
            'db_operation_not_allowed',
            'db.insert() 需要执行写语句',
          );
        }
        statement.executeWith(normalizedArguments);
        return {
          'changes': database.updatedRows,
          'lastInsertRowId': database.lastInsertRowId.toString(),
        };
      case PlaymeshDatabaseOperation.update:
        if (statement.isReadOnly) {
          throw const PlaymeshDatabaseException(
            'db_operation_not_allowed',
            'db.update() 需要执行写语句',
          );
        }
        statement.executeWith(normalizedArguments);
        return {'changes': database.updatedRows};
      case PlaymeshDatabaseOperation.delete:
        if (statement.isReadOnly) {
          throw const PlaymeshDatabaseException(
            'db_operation_not_allowed',
            'db.delete() 需要执行写语句',
          );
        }
        statement.executeWith(normalizedArguments);
        return {'changes': database.updatedRows};
    }
  } finally {
    statement?.close();
  }
}

StatementParameters _statementParameters(Object arguments) {
  Object? normalize(Object? value) => switch (value) {
    null => null,
    bool value => value ? 1 : 0,
    int value => value,
    double value when value.isFinite => value,
    String value => value,
    _ => throw const PlaymeshDatabaseException(
      'db_parameter_invalid',
      'SQL 参数只能是 null、boolean、number 或 string',
    ),
  };

  if (arguments is List) {
    return StatementParameters([
      for (final value in arguments) normalize(value),
    ]);
  }
  if (arguments is Map && arguments.keys.every((key) => key is String)) {
    return StatementParameters.named({
      for (final entry in arguments.entries)
        _namedParameterKey(entry.key as String): normalize(entry.value),
    });
  }
  throw const PlaymeshDatabaseException(
    'db_parameter_invalid',
    'SQL args 必须是数组或命名参数对象',
  );
}

String _namedParameterKey(String key) {
  if (key.startsWith(':') || key.startsWith('@') || key.startsWith(r'$')) {
    return key;
  }
  return ':$key';
}

List<Map<String, Object?>> _select(
  PreparedStatement statement,
  StatementParameters arguments,
) {
  final resultSet = statement.selectWith(arguments);
  final columns = resultSet.columnNames;
  final rows = <Map<String, Object?>>[];
  for (final row in resultSet) {
    rows.add({
      for (var index = 0; index < columns.length; index += 1)
        columns[index]: _jsonDatabaseValue(row.columnAt(index)),
    });
  }
  return rows;
}

bool _isAllowedTableStatement(bool readOnly, List<String> tokens) {
  if (tokens.isEmpty) return false;
  final first = tokens.first;
  if (readOnly) return const {'SELECT', 'WITH', 'VALUES'}.contains(first);
  if (const {'INSERT', 'REPLACE', 'UPDATE', 'DELETE', 'WITH'}.contains(first)) {
    return true;
  }
  if (first == 'ALTER') return tokens.length > 1 && tokens[1] == 'TABLE';
  if (first == 'DROP') {
    return tokens.length > 1 && const {'TABLE', 'INDEX'}.contains(tokens[1]);
  }
  if (first != 'CREATE' || tokens.length < 2) return false;
  if (const {'TABLE', 'INDEX'}.contains(tokens[1])) return true;
  return tokens.length > 2 && tokens[1] == 'UNIQUE' && tokens[2] == 'INDEX';
}

/// Extracts keywords only after SQLite has successfully prepared the statement.
/// It does not validate SQL or produce syntax errors; SQLite remains the parser.
List<String> _statementTokens(String sql) {
  final tokens = <String>[];
  var index = 0;
  while (index < sql.length) {
    final code = sql.codeUnitAt(index);
    if (code == 45 &&
        index + 1 < sql.length &&
        sql.codeUnitAt(index + 1) == 45) {
      index += 2;
      while (index < sql.length &&
          sql.codeUnitAt(index) != 10 &&
          sql.codeUnitAt(index) != 13) {
        index += 1;
      }
      continue;
    }
    if (code == 47 &&
        index + 1 < sql.length &&
        sql.codeUnitAt(index + 1) == 42) {
      final end = sql.indexOf('*/', index + 2);
      index = end < 0 ? sql.length : end + 2;
      continue;
    }
    if (code == 39 || code == 34 || code == 96 || code == 91) {
      final close = code == 91 ? 93 : code;
      index += 1;
      while (index < sql.length) {
        if (sql.codeUnitAt(index) == close) {
          if (close != 93 &&
              index + 1 < sql.length &&
              sql.codeUnitAt(index + 1) == close) {
            index += 2;
            continue;
          }
          index += 1;
          break;
        }
        index += 1;
      }
      continue;
    }
    if (_isSqlIdentifierStart(code)) {
      final start = index++;
      while (index < sql.length &&
          _isSqlIdentifierPart(sql.codeUnitAt(index))) {
        index += 1;
      }
      tokens.add(sql.substring(start, index).toUpperCase());
      if (tokens.length == 3) return tokens;
      continue;
    }
    index += 1;
  }
  return tokens;
}

bool _isSqlIdentifierStart(int code) =>
    (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95;

bool _isSqlIdentifierPart(int code) =>
    _isSqlIdentifierStart(code) || (code >= 48 && code <= 57);

Object? _jsonDatabaseValue(Object? value) {
  const maxSafeInteger = 9007199254740991;
  return switch (value) {
    null => null,
    int value when value > maxSafeInteger || value < -maxSafeInteger =>
      value.toString(),
    int value => value,
    double value when value.isFinite => value,
    String value => value,
    Uint8List value => value.toList(growable: false),
    _ => throw const PlaymeshDatabaseException(
      'db_value_unsupported',
      '查询返回了 SDK 不支持的数据类型',
    ),
  };
}

Map<String, Object?> _workerErrorResponse(Object error) {
  final translated = error is PlaymeshDatabaseException
      ? error
      : _translateDatabaseError(error);
  return {'ok': false, 'code': translated.code, 'message': translated.message};
}

PlaymeshDatabaseException _errorFromWorkerResponse(Object? response) {
  if (response is Map) {
    final code = response['code'];
    final message = response['message'];
    if (code is String && message is String) {
      return PlaymeshDatabaseException(code, message);
    }
  }
  return const PlaymeshDatabaseException('db_worker_failed', '数据库后台连接异常退出');
}

PlaymeshDatabaseException _translateDatabaseError(Object error) {
  if (error is PlaymeshDatabaseException) return error;
  if (error is SqliteException) {
    final code = switch (error.resultCode) {
      SqlError.SQLITE_BUSY || SqlError.SQLITE_LOCKED => 'db_busy',
      SqlError.SQLITE_CONSTRAINT => 'db_constraint',
      SqlError.SQLITE_READONLY => 'db_readonly',
      SqlError.SQLITE_FULL => 'db_full',
      SqlError.SQLITE_CORRUPT || SqlError.SQLITE_NOTADB => 'db_corrupt',
      SqlError.SQLITE_IOERR || SqlError.SQLITE_CANTOPEN => 'db_io_error',
      _ => 'db_sqlite_error',
    };
    return PlaymeshDatabaseException(code, error.message);
  }
  return PlaymeshDatabaseException('db_failed', error.toString());
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
