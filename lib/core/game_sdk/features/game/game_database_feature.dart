part of '../../sdk_feature_registry.dart';

const gameDatabaseSdkSource = SdkSourceFragment(
  id: 'game.database',
  target: SdkSourceTarget.game,
  order: 65,
  typeScript: r'''
  function validateDatabaseSql(sql) {
    if (typeof sql !== "string" || sql.trim().length === 0) {
      throw new Error("SQL 必须是非空字符串");
    }
    return sql;
  }

  function validateDatabaseArguments(args) {
    if (args === undefined) return [];
    const indexed = Array.isArray(args);
    if (
      !indexed &&
      (!args || typeof args !== "object" || Object.getPrototypeOf(args) !== Object.prototype)
    ) {
      throw new Error("SQL args 必须是数组或命名参数对象");
    }
    for (const value of indexed ? args : Object.values(args)) {
      if (
        value !== null &&
        typeof value !== "boolean" &&
        typeof value !== "number" &&
        typeof value !== "string"
      ) {
        throw new Error("SQL 参数只能是 null、boolean、number 或 string");
      }
      if (typeof value === "number" && !Number.isFinite(value)) {
        throw new Error("SQL number 参数必须是有限数值");
      }
    }
    return indexed ? args.slice() : { ...args };
  }

  function requireDatabaseAuthority() {
    if (!main.session.isAuthority()) {
      throw new Error("只有 Authority Client 可以访问 main.db");
    }
  }

  function databaseStatementCall(command, sql, args, transactionId) {
    requireDatabaseAuthority();
    const payload = {
      sql: validateDatabaseSql(sql),
      args: validateDatabaseArguments(args),
    };
    if (transactionId !== undefined) payload.transactionId = transactionId;
    switch (command) {
      case "db.select": return post("db.select", payload);
      case "db.update": return post("db.update", payload);
      case "db.delete": return post("db.delete", payload);
      case "db.insert": return post("db.insert", payload);
      case "db.transaction.select":
        return post("db.transaction.select", payload);
      case "db.transaction.update":
        return post("db.transaction.update", payload);
      case "db.transaction.delete":
        return post("db.transaction.delete", payload);
      case "db.transaction.insert":
        return post("db.transaction.insert", payload);
      default: throw new Error(`未知数据库命令: ${command}`);
    }
  }

  function createDatabaseTransaction(transactionId) {
    let active = true;
    function requireActive() {
      if (!active) throw new Error("数据库事务已经结束");
    }
    return Object.freeze({
      select(sql, args) {
        requireActive();
        return databaseStatementCall(
          "db.transaction.select",
          sql,
          args,
          transactionId,
        );
      },
      update(sql, args) {
        requireActive();
        return databaseStatementCall(
          "db.transaction.update",
          sql,
          args,
          transactionId,
        );
      },
      delete(sql, args) {
        requireActive();
        return databaseStatementCall(
          "db.transaction.delete",
          sql,
          args,
          transactionId,
        );
      },
      insert(sql, args) {
        requireActive();
        return databaseStatementCall(
          "db.transaction.insert",
          sql,
          args,
          transactionId,
        );
      },
      getDDL(name) {
        requireActive();
        return databaseDdlCall(name, transactionId);
      },
      async commit() {
        requireActive();
        requireDatabaseAuthority();
        await post("db.transaction.commit", { transactionId });
        active = false;
      },
      async rollback() {
        requireActive();
        requireDatabaseAuthority();
        await post("db.transaction.rollback", { transactionId });
        active = false;
      },
    });
  }

  function databaseDdlCall(name, transactionId) {
    requireDatabaseAuthority();
    if (
      name !== undefined &&
      (typeof name !== "string" || name.trim().length === 0)
    ) {
      throw new Error("DDL 名称必须是非空字符串");
    }
    const payload = {};
    if (name !== undefined) payload.name = name;
    if (transactionId !== undefined) payload.transactionId = transactionId;
    return transactionId === undefined
      ? post("db.ddl", payload)
      : post("db.transaction.ddl", payload);
  }

  function createDatabaseApi() {
    return Object.freeze({
      open() {
        requireDatabaseAuthority();
        return post("db.open", {});
      },
      select(sql, args) {
        return databaseStatementCall("db.select", sql, args);
      },
      update(sql, args) {
        return databaseStatementCall("db.update", sql, args);
      },
      delete(sql, args) {
        return databaseStatementCall("db.delete", sql, args);
      },
      insert(sql, args) {
        return databaseStatementCall("db.insert", sql, args);
      },
      getDDL(name) {
        return databaseDdlCall(name);
      },
      async beginTransaction() {
        requireDatabaseAuthority();
        const result = await post("db.transaction.begin", {});
        return createDatabaseTransaction(result.transactionId);
      },
      async transaction(callback) {
        requireDatabaseAuthority();
        if (typeof callback !== "function") {
          throw new Error("db.transaction() callback 必须是函数");
        }
        const result = await post("db.transaction.begin", {});
        const transaction = createDatabaseTransaction(result.transactionId);
        try {
          const result = await callback(transaction);
          await transaction.commit();
          return result;
        } catch (error) {
          try {
            await transaction.rollback();
          } catch (rollbackError) {
            global.console?.error?.("数据库事务自动回滚失败", rollbackError);
          }
          throw error;
        }
      },
    });
  }

''',
  declaration: r'''
/** SQLite 可传输参数和结果值。超出 JavaScript 安全整数范围的 INTEGER 以十进制字符串返回。 */
type PlaymeshDatabaseValue = null | number | string | readonly number[];
type PlaymeshDatabaseParameter = null | boolean | number | string;
type PlaymeshDatabaseArguments = readonly PlaymeshDatabaseParameter[] |
  Readonly<Record<string, PlaymeshDatabaseParameter>>;

interface PlaymeshDatabaseChangeResult {
  readonly changes: number;
}

interface PlaymeshDatabaseInsertResult extends PlaymeshDatabaseChangeResult {
  readonly lastInsertRowId: string;
}

interface PlaymeshDatabaseDdl {
  readonly type: "table" | "index";
  readonly name: string;
  readonly tableName: string;
  readonly sql: string;
}

interface PlaymeshDatabaseTransaction {
  /** 使用预编译语句查询；支持位置占位符和命名占位符，参数不会拼接到 SQL。 */
  select<T extends Record<string, PlaymeshDatabaseValue> = Record<string, PlaymeshDatabaseValue>>(sql: string, args?: PlaymeshDatabaseArguments): Promise<T[]>;
  /** 执行 UPDATE 或受支持的表/索引 DDL。 */
  update(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseChangeResult>;
  /** 执行 DELETE。 */
  delete(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseChangeResult>;
  /** 执行 INSERT 或 REPLACE。 */
  insert(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseInsertResult>;
  /** 返回事务连接内的原生表/索引 DDL；传名称时返回该表及其索引。 */
  getDDL(name?: string): Promise<PlaymeshDatabaseDdl[]>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
}

interface PlaymeshDatabaseApi {
  /** 打开或创建当前游戏 `data/db/` 目录下固定的 `_game.db`。 @playmesh-completion playmesh.main.db.open */
  open(): Promise<{ readonly file: "_game.db" }>;
  /** 使用预编译语句查询；数组绑定 `?`/`?NNN`。对象键 `name` 绑定 `:name`，也可传完整的 `:name`/`@name`/`$name`。 @playmesh-completion playmesh.main.db.select */
  select<T extends Record<string, PlaymeshDatabaseValue> = Record<string, PlaymeshDatabaseValue>>(sql: string, args?: PlaymeshDatabaseArguments): Promise<T[]>;
  /** 执行表级写 SQL。 @playmesh-completion playmesh.main.db.update */
  update(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseChangeResult>;
  /** 执行表级写 SQL。 @playmesh-completion playmesh.main.db.delete */
  delete(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseChangeResult>;
  /** 执行表级写 SQL。 @playmesh-completion playmesh.main.db.insert */
  insert(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseInsertResult>;
  /** 返回原生表/索引 DDL；传名称时返回该表及其索引。 @playmesh-completion playmesh.main.db.getDDL */
  getDDL(name?: string): Promise<PlaymeshDatabaseDdl[]>;
  /** 在一条独立 SQLite 连接上开始事务。 @playmesh-completion playmesh.main.db.beginTransaction */
  beginTransaction(): Promise<PlaymeshDatabaseTransaction>;
  /** 自动开始事务；回调成功后提交，抛错后回滚并重新抛出原错误。 @playmesh-completion playmesh.main.db.transaction */
  transaction<T>(callback: (transaction: PlaymeshDatabaseTransaction) => T | Promise<T>): Promise<T>;
}

interface PlaymeshMainApi {
  /** Authority 专用 SQLite；多连接 WAL 允许并发读取，但 SQLite 写入仍串行提交。 */
  readonly db: PlaymeshDatabaseApi;
}
''',
);

final class _GameDatabaseFeature implements _GameSdkCommandFeature {
  static const _statementCommands = {
    'db.select': PlaymeshDatabaseOperation.select,
    'db.update': PlaymeshDatabaseOperation.update,
    'db.delete': PlaymeshDatabaseOperation.delete,
    'db.insert': PlaymeshDatabaseOperation.insert,
    'db.transaction.select': PlaymeshDatabaseOperation.select,
    'db.transaction.update': PlaymeshDatabaseOperation.update,
    'db.transaction.delete': PlaymeshDatabaseOperation.delete,
    'db.transaction.insert': PlaymeshDatabaseOperation.insert,
  };

  @override
  SdkSourceFragment get source => gameDatabaseSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('4.2.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {
    'db.open',
    'db.select',
    'db.update',
    'db.delete',
    'db.insert',
    'db.ddl',
    'db.transaction.begin',
    'db.transaction.select',
    'db.transaction.update',
    'db.transaction.delete',
    'db.transaction.insert',
    'db.transaction.ddl',
    'db.transaction.commit',
    'db.transaction.rollback',
  };

  @override
  Future<SdkCommandExecution> execute(
    GameSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    _requireAuthority(context);
    final ensureDatabase = context.ensureDatabase;
    if (ensureDatabase == null) {
      throw const SdkCommandException('db_unavailable', '当前宿主没有提供数据库能力');
    }
    try {
      final database = await ensureDatabase();
      if (command.name == 'db.open') {
        _requireExactPayload(command.payload, const {});
        await database.open();
        return const SdkCommandResult({'file': '_game.db'});
      }
      if (command.name == 'db.transaction.begin') {
        _requireExactPayload(command.payload, const {});
        return SdkCommandResult({
          'transactionId': await database.beginTransaction(),
        });
      }
      if (command.name == 'db.transaction.commit' ||
          command.name == 'db.transaction.rollback') {
        _requireExactPayload(command.payload, const {'transactionId'});
        final transactionId = sdkRequiredString(
          command.payload,
          'transactionId',
        );
        if (command.name == 'db.transaction.commit') {
          await database.commitTransaction(transactionId);
        } else {
          await database.rollbackTransaction(transactionId);
        }
        return const SdkCommandResult();
      }
      if (command.name == 'db.ddl' || command.name == 'db.transaction.ddl') {
        final transactionCommand = command.name == 'db.transaction.ddl';
        final allowedKeys = transactionCommand
            ? const {'transactionId', 'name'}
            : const {'name'};
        if (!command.payload.keys.every(allowedKeys.contains) ||
            (transactionCommand &&
                !command.payload.containsKey('transactionId'))) {
          throw const SdkCommandException('db_request_invalid', 'DDL 请求参数无效');
        }
        final rawName = command.payload['name'];
        if (rawName != null && (rawName is! String || rawName.isEmpty)) {
          throw const SdkCommandException(
            'db_request_invalid',
            'DDL 名称必须是非空字符串',
          );
        }
        final name = rawName as String?;
        final result = transactionCommand
            ? await database.getTransactionDdl(
                sdkRequiredString(command.payload, 'transactionId'),
                name,
              )
            : await database.getDdl(name);
        return SdkCommandResult(result);
      }
      final operation = _statementCommands[command.name];
      if (operation == null) {
        throw StateError('未注册的数据库命令: ${command.name}');
      }
      final transactionCommand = command.name.startsWith('db.transaction.');
      _requireExactPayload(
        command.payload,
        transactionCommand
            ? const {'transactionId', 'sql', 'args'}
            : const {'sql', 'args'},
      );
      final sql = sdkRequiredString(command.payload, 'sql');
      final rawArguments = command.payload['args'];
      if (rawArguments is! List &&
          (rawArguments is! Map ||
              !rawArguments.keys.every((key) => key is String))) {
        throw const SdkCommandException(
          'db_parameter_invalid',
          'SQL args 必须是数组或命名参数对象',
        );
      }
      final arguments = rawArguments is List
          ? List<Object?>.from(rawArguments)
          : Map<String, Object?>.from(rawArguments as Map);
      final result = transactionCommand
          ? await database.executeTransaction(
              sdkRequiredString(command.payload, 'transactionId'),
              operation,
              sql,
              arguments,
            )
          : await database.execute(operation, sql, arguments);
      return SdkCommandResult(result);
    } on PlaymeshDatabaseException catch (error) {
      throw SdkCommandException(error.code, error.message);
    }
  }

  void _requireAuthority(GameSdkCommandContext context) {
    if (!context.isAuthority) {
      throw const SdkCommandException(
        'not_authority',
        '只有 Authority Client 可以访问 main.db',
      );
    }
  }

  void _requireExactPayload(
    Map<String, Object?> payload,
    Set<String> expectedKeys,
  ) {
    if (payload.length != expectedKeys.length ||
        !payload.keys.every(expectedKeys.contains)) {
      throw const SdkCommandException('db_request_invalid', '数据库命令参数无效');
    }
  }
}
