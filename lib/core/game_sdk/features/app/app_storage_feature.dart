part of '../../sdk_feature_registry.dart';

const appStorageSdkSource = SdkSourceFragment(
  id: 'app.storage',
  target: SdkSourceTarget.app,
  order: 21,
  typeScript: r'''
  const APP_STORAGE_BUCKET_PATTERN =
    /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
  const APP_STORAGE_KEY_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;

  function validateAppStorageBucket(bucket) {
    if (typeof bucket !== "string" ||
        !APP_STORAGE_BUCKET_PATTERN.test(bucket)) {
      throw new TypeError(
        "App Bucket 名称必须以字母或数字开头，只能包含字母、数字、下划线和连字符，且不超过 64 个字符",
      );
    }
  }

  function validateAppStorageKey(key) {
    if (typeof key !== "string" || !APP_STORAGE_KEY_PATTERN.test(key)) {
      throw new TypeError(
        "App Bucket key 只能包含字母、数字、点、下划线和连字符，且长度为 1 至 128",
      );
    }
  }

  function cloneAppStorageJson(value) {
    try {
      const encoded = JSON.stringify(value);
      if (typeof encoded !== "string") throw new TypeError();
      return JSON.parse(encoded);
    } catch (_) {
      throw new TypeError("App Bucket 只能写入 JSON 值");
    }
  }

  function browserAppStorage() {
    const storage = global.localStorage;
    if (!storage?.getItem || !storage?.setItem || !storage?.removeItem) {
      throw new Error("当前浏览器不支持 localStorage");
    }
    return storage;
  }

  function readBrowserAppBucket(bucket) {
    const raw = browserAppStorage().getItem(bucket);
    if (raw === null) return {};
    const decoded = JSON.parse(raw);
    if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) {
      throw new Error("App Bucket localStorage 根节点必须是对象");
    }
    for (const key of Object.keys(decoded)) validateAppStorageKey(key);
    return decoded;
  }

  function browserAppStorageCall(operation, bucket, key, value) {
    const storage = browserAppStorage();
    if (operation === "get") {
      const values = readBrowserAppBucket(bucket);
      return Object.prototype.hasOwnProperty.call(values, key)
        ? cloneAppStorageJson(values[key])
        : null;
    }
    if (operation === "clear") {
      storage.removeItem(bucket);
      return null;
    }
    const values = readBrowserAppBucket(bucket);
    if (operation === "set") {
      values[key] = cloneAppStorageJson(value);
    } else if (operation === "remove") {
      delete values[key];
    } else {
      throw new Error(`未知 App Bucket 操作: ${operation}`);
    }
    storage.setItem(bucket, JSON.stringify(values));
    return null;
  }

  function appStorageCall(operation, bucket, key, value) {
    if (nativeSender() !== null) {
      if (operation === "get") {
        return request("app.storage.get", { bucket, key });
      }
      if (operation === "set") {
        return request("app.storage.set", { bucket, key, value });
      }
      if (operation === "remove") {
        return request("app.storage.remove", { bucket, key });
      }
      if (operation === "clear") {
        return request("app.storage.clear", { bucket });
      }
      return Promise.reject(
        new Error(`未知 App Bucket 操作: ${operation}`),
      );
    }
    try {
      return Promise.resolve(
        browserAppStorageCall(operation, bucket, key, value),
      );
    } catch (error) {
      return Promise.reject(error);
    }
  }

  const appStorageApi = Object.freeze({
    getBucket(bucket) {
      validateAppStorageBucket(bucket);
      return Object.freeze({
        getData(key) {
          validateAppStorageKey(key);
          return appStorageCall("get", bucket, key);
        },
        setData(key, value) {
          validateAppStorageKey(key);
          const cloned = cloneAppStorageJson(value);
          return appStorageCall("set", bucket, key, cloned);
        },
        removeData(key) {
          validateAppStorageKey(key);
          return appStorageCall("remove", bucket, key);
        },
        clearData() {
          return appStorageCall("clear", bucket);
        },
      });
    },
  });
''',
  declaration: r'''
/** 当前设备独占的 App JSON Bucket；不会与 Authority 或其他玩家共享。 */
interface PlaymeshAppStorageBucket {
  /** 读取 key；不存在时返回 `null`。 */
  getData<T = PlaymeshJson>(key: string): Promise<T | null>;
  /** 在当前设备写入 JSON 值。 */
  setData(key: string, value: PlaymeshJson): Promise<void>;
  /** 在当前设备删除一个 key。 */
  removeData(key: string): Promise<void>;
  /** 清空当前设备上的当前 Bucket。 */
  clearData(): Promise<void>;
}

interface PlaymeshAppApi {
  /** 当前设备独占的玩家本地 JSON 存储，不通过 Authority 或游戏会话共享。 */
  readonly storage: {
    /** 获取本地 Bucket；名称规则与 Main Bucket 相同。 @playmesh-completion playmesh.app.storage.getBucket */
    getBucket(bucket: string): PlaymeshAppStorageBucket;
  };
}
''',
);

final class _AppStorageFeature implements _AppSdkCommandFeature {
  @override
  SdkSourceFragment get source => appStorageSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {
    'app.storage.get',
    'app.storage.set',
    'app.storage.remove',
    'app.storage.clear',
  };

  @override
  Future<Object?> execute(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    final store = context.localBucketStore;
    if (store == null) {
      throw const SdkCommandException(
        'game_context_unavailable',
        '当前页面没有可用的本地游戏存储上下文',
      );
    }
    final payload = command.payload;
    final expectedKeys = switch (command.name) {
      'app.storage.get' || 'app.storage.remove' => const {'bucket', 'key'},
      'app.storage.set' => const {'bucket', 'key', 'value'},
      'app.storage.clear' => const {'bucket'},
      _ => throw StateError('未注册的 App Bucket 命令: ${command.name}'),
    };
    if (payload.length != expectedKeys.length ||
        !payload.keys.every(expectedKeys.contains)) {
      throw const SdkCommandException('invalid_argument', 'App Bucket 命令参数无效');
    }
    final bucket = payload['bucket'];
    if (bucket is! String) {
      throw const SdkCommandException('invalid_argument', 'App Bucket 名称无效');
    }
    final key = payload['key'];
    if (command.name != 'app.storage.clear' && key is! String) {
      throw const SdkCommandException('invalid_argument', 'App Bucket key 无效');
    }
    try {
      switch (command.name) {
        case 'app.storage.get':
          return store.getData(bucket, key! as String);
        case 'app.storage.set':
          await store.setData(bucket, key! as String, payload['value']);
          return null;
        case 'app.storage.remove':
          await store.removeData(bucket, key! as String);
          return null;
        case 'app.storage.clear':
          await store.clearData(bucket);
          return null;
      }
    } on FormatException catch (error) {
      throw SdkCommandException('invalid_argument', error.message);
    }
    throw StateError('未注册的 App Bucket 命令: ${command.name}');
  }
}
