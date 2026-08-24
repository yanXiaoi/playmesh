part of '../../sdk_feature_registry.dart';

const appStorageSdkSource = SdkSourceFragment(
  id: 'app.storage',
  target: SdkSourceTarget.app,
  order: 21,
  typeScript: r'''
  const APP_STORAGE_BUCKET_PATTERN =
    /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
  const APP_STORAGE_KEY_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;
  const APP_STORAGE_GDEVELOP_ROOT_KEY = "$playmesh.gdevelop.root.v1";
  let appStorageSyncConfiguration = null;

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

  function appStorageUtf8Bytes(value) {
    if (typeof global.TextEncoder === "function") {
      return new global.TextEncoder().encode(value);
    }
    const encoded = unescape(encodeURIComponent(value));
    return Uint8Array.from(encoded, (character) => character.charCodeAt(0));
  }

  function validateSynchronousAppStorageBucket(bucket) {
    if (typeof bucket !== "string") {
      throw new TypeError("同步 App Bucket 逻辑名必须是字符串");
    }
    const length = appStorageUtf8Bytes(bucket).length;
    if (length < 1 || length > 4096) {
      throw new TypeError(
        "同步 App Bucket 逻辑名必须为 1 至 4096 个 UTF-8 字节",
      );
    }
  }

  function validateSynchronousAppStorageKey(key) {
    if (key === APP_STORAGE_GDEVELOP_ROOT_KEY) return;
    validateAppStorageKey(key);
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
    for (const key of Object.keys(decoded)) validateSynchronousAppStorageKey(key);
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

  function configureAppStorageSync(configuration) {
    const endpoint = configuration?.endpoint;
    appStorageSyncConfiguration = typeof endpoint === "string" &&
        /^http:\/\/127\.0\.0\.1:\d+\/playmesh\/app-storage-sync\/v1\/[A-Za-z0-9_-]{43}$/.test(endpoint)
      ? Object.freeze({ endpoint })
      : null;
  }

  function appStorageBase64Url(bytes) {
    let binary = "";
    for (const value of bytes) binary += String.fromCharCode(value);
    return global.btoa(binary)
      .replaceAll("+", "-")
      .replaceAll("/", "_")
      .replace(/=+$/g, "");
  }

  function appStorageCallSync(operation, bucket, key, value) {
    if (nativeSender() === null) {
      return browserAppStorageCall(
        operation === "sync.get" ? "get" : "set",
        bucket,
        key,
        value,
      );
    }
    const configuration = appStorageSyncConfiguration;
    if (!configuration) {
      throw new Error(
        "Playmesh App SDK 尚未就绪，App Bucket 同步存储不可用",
      );
    }
    if (typeof global.XMLHttpRequest !== "function") {
      throw new Error("当前 WebView 不支持 App Bucket 同步 XMLHttpRequest");
    }
    const requestId = `app-storage-sync-${Date.now()}-${++sequence}`;
    const envelope = operation === "sync.get"
      ? {
          protocolVersion: "1.0.0",
          requestId,
          operation,
          bucket,
          key,
        }
      : {
          protocolVersion: "1.0.0",
          requestId,
          operation,
          bucket,
          key,
          value,
        };
    const body = JSON.stringify(envelope);
    const method = operation === "sync.get" ? "GET" : "POST";
    const url = method === "GET"
      ? `${configuration.endpoint}?payload=${appStorageBase64Url(
          appStorageUtf8Bytes(body),
        )}`
      : configuration.endpoint;
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const xhr = new global.XMLHttpRequest();
        xhr.open(method, url, false);
        if (method === "POST") {
          xhr.setRequestHeader("Content-Type", "text/plain;charset=UTF-8");
        }
        xhr.send(method === "POST" ? body : null);
        const payload = JSON.parse(xhr.responseText || "");
        if (xhr.status < 200 || xhr.status >= 300 || payload?.error) {
          const error = new Error(
            payload?.error?.message || `App Bucket 同步请求失败: HTTP ${xhr.status}`,
          );
          if (typeof payload?.error?.code === "string") {
            error.code = payload.error.code;
          }
          throw error;
        }
        if (payload?.protocolVersion !== "1.0.0" ||
            payload?.requestId !== requestId ||
            !Object.prototype.hasOwnProperty.call(payload, "result")) {
          throw new Error("App Bucket 同步响应无效");
        }
        return payload.result;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError || new Error("App Bucket 同步请求失败");
  }

  const appStorageApi = Object.freeze({
    getBucket(bucket) {
      validateSynchronousAppStorageBucket(bucket);
      return Object.freeze({
        getData(key) {
          validateAppStorageBucket(bucket);
          validateAppStorageKey(key);
          return appStorageCall("get", bucket, key);
        },
        setData(key, value) {
          validateAppStorageBucket(bucket);
          validateAppStorageKey(key);
          const cloned = cloneAppStorageJson(value);
          return appStorageCall("set", bucket, key, cloned);
        },
        getDataSync(key) {
          validateSynchronousAppStorageKey(key);
          return cloneAppStorageJson(
            appStorageCallSync("sync.get", bucket, key),
          );
        },
        setDataSync(key, value) {
          validateSynchronousAppStorageKey(key);
          const cloned = cloneAppStorageJson(value);
          appStorageCallSync("sync.set", bucket, key, cloned);
        },
        removeData(key) {
          validateAppStorageBucket(bucket);
          validateAppStorageKey(key);
          return appStorageCall("remove", bucket, key);
        },
        clearData() {
          validateAppStorageBucket(bucket);
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
  /** 阻塞读取当前设备的 JSON；不存在时返回 `null`。 */
  getDataSync<T = PlaymeshJson>(key: string): T | null;
  /** 阻塞写入当前设备的 JSON；返回时本地文件已提交。 */
  setDataSync(key: string, value: PlaymeshJson): void;
  /** 在当前设备删除一个 key。 */
  removeData(key: string): Promise<void>;
  /** 清空当前设备上的当前 Bucket。 */
  clearData(): Promise<void>;
}

interface PlaymeshAppApi {
  /** 当前设备独占的玩家本地 JSON 存储，不通过 Authority 或游戏会话共享。 */
  readonly storage: {
    /** 获取本地 Bucket；异步方法使用标准名称规则，同步方法另支持 1～4096 UTF-8 字节逻辑名。 @playmesh-completion playmesh.app.storage.getBucket */
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
