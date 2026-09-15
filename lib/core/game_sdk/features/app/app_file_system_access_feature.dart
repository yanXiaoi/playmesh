part of '../../sdk_feature_registry.dart';

const appFileSystemAccessSdkSource = SdkSourceFragment(
  id: 'app.fileSystemAccess',
  target: SdkSourceTarget.app,
  order: 28,
  typeScript: r'''
  const PLAYMESH_FILE_TRANSFER_CHUNK = 512 * 1024;

  function fileSystemDomException(error) {
    const names = {
      user_cancelled: "AbortError",
      not_allowed: "NotAllowedError",
      not_found: "NotFoundError",
      type_mismatch: "TypeMismatchError",
      invalid_modification: "InvalidModificationError",
      invalid_state: "InvalidStateError",
      not_supported: "NotSupportedError",
    };
    const name = names[error?.code] || "UnknownError";
    const message = error?.message || "Playmesh 文件系统操作失败";
    if (typeof global.DOMException === "function") {
      return new global.DOMException(message, name);
    }
    const fallback = new Error(message);
    fallback.name = name;
    return fallback;
  }

  function fileSystemRequest(command, payload = {}) {
    const timeout = command.startsWith("pick") ? null : 30000;
    return request(`app.fileSystem.${command}`, payload, timeout).catch((error) => {
      throw fileSystemDomException(error);
    });
  }

  function normalizeFilePickerTypes(rawTypes, excludeAcceptAllOption) {
    if (rawTypes == null) {
      if (excludeAcceptAllOption === true) {
        throw new TypeError("excludeAcceptAllOption 为 true 时必须提供 types");
      }
      return [];
    }
    if (!Array.isArray(rawTypes)) throw new TypeError("types 必须是数组");
    const types = rawTypes.map((rawType) => {
      if (!rawType || typeof rawType !== "object") {
        throw new TypeError("types 中的条目必须是对象");
      }
      const description = rawType.description == null ? "" : String(rawType.description);
      const rawAccept = rawType.accept;
      if (!rawAccept || typeof rawAccept !== "object" || Array.isArray(rawAccept)) {
        throw new TypeError("文件类型的 accept 必须是对象");
      }
      const accept = {};
      for (const [mime, rawExtensions] of Object.entries(rawAccept)) {
        if (typeof mime !== "string" || !mime.includes("/")) {
          throw new TypeError("accept 的键必须是 MIME 类型");
        }
        const extensions = Array.isArray(rawExtensions) ? rawExtensions : [rawExtensions];
        accept[mime] = extensions.map((extension) => {
          if (typeof extension !== "string" || !/^\.[A-Za-z0-9][A-Za-z0-9._+-]{0,31}$/.test(extension)) {
            throw new TypeError(`无效的文件扩展名：${extension}`);
          }
          return extension.toLowerCase();
        });
      }
      return { description, accept };
    });
    if (excludeAcceptAllOption === true && types.length === 0) {
      throw new TypeError("excludeAcceptAllOption 为 true 时 types 不能为空");
    }
    return types;
  }

  function normalizeFilePickerOptions(rawOptions, kind) {
    const options = rawOptions == null ? {} : rawOptions;
    if (typeof options !== "object") throw new TypeError("选取器参数必须是对象");
    const payload = {};
    if (kind !== "directory") {
      payload.types = normalizeFilePickerTypes(options.types, options.excludeAcceptAllOption);
      payload.excludeAcceptAllOption = options.excludeAcceptAllOption === true;
    }
    if (kind === "open") payload.multiple = options.multiple === true;
    if (kind === "save" && options.suggestedName != null) {
      payload.suggestedName = String(options.suggestedName);
    }
    if (options.startIn instanceof PlaymeshFileSystemHandle) payload.startInId = options.startIn._id;
    if (kind === "directory" && options.mode != null) {
      if (options.mode !== "read" && options.mode !== "readwrite") {
        throw new TypeError("mode 必须是 read 或 readwrite");
      }
      payload.mode = options.mode;
    }
    return payload;
  }

  function bytesFromBase64(value) {
    const binary = global.atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
  }

  function bytesToBase64(bytes) {
    let binary = "";
    const stride = 0x8000;
    for (let offset = 0; offset < bytes.length; offset += stride) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + stride));
    }
    return global.btoa(binary);
  }

  async function bytesForFileSystemWrite(value) {
    if (typeof value === "string") return new TextEncoder().encode(value);
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    if (typeof global.Blob === "function" && value instanceof global.Blob) {
      return new Uint8Array(await value.arrayBuffer());
    }
    throw new TypeError("write 只接受字符串、Blob、ArrayBuffer 或 TypedArray");
  }

  class PlaymeshFileSystemHandle {
    constructor(descriptor) {
      Object.defineProperty(this, "_id", { value: descriptor.id, enumerable: false });
      Object.defineProperties(this, {
        kind: { value: descriptor.kind, enumerable: true },
        name: { value: descriptor.name, enumerable: true },
      });
    }

    async isSameEntry(other) {
      if (!(other instanceof PlaymeshFileSystemHandle)) return false;
      return fileSystemRequest("same", { id: this._id, otherId: other._id });
    }

    async queryPermission(options = {}) {
      if (options.mode != null && options.mode !== "read" && options.mode !== "readwrite") {
        throw new TypeError("mode 必须是 read 或 readwrite");
      }
      return "granted";
    }

    async requestPermission(options = {}) { return this.queryPermission(options); }
    get [Symbol.toStringTag]() { return "FileSystemHandle"; }
  }

  class PlaymeshFileSystemFileHandle extends PlaymeshFileSystemHandle {
    async getFile() {
      const metadata = await fileSystemRequest("stat", { id: this._id });
      const chunks = [];
      let offset = 0;
      while (offset < metadata.size) {
        const result = await fileSystemRequest("read", {
          id: this._id,
          offset,
          length: Math.min(PLAYMESH_FILE_TRANSFER_CHUNK, metadata.size - offset),
        });
        const bytes = bytesFromBase64(result.data || "");
        if (bytes.length === 0 && !result.eof) {
          throw new DOMException("文件读取没有进展", "NotReadableError");
        }
        chunks.push(bytes);
        offset += bytes.length;
        if (result.eof) break;
      }
      return new global.File(chunks, metadata.name, {
        type: metadata.type || "",
        lastModified: metadata.lastModified,
      });
    }

    async createWritable(options = {}) {
      if (!options || typeof options !== "object") throw new TypeError("createWritable 参数必须是对象");
      const result = await fileSystemRequest("createWritable", {
        id: this._id,
        keepExistingData: options.keepExistingData === true,
      });
      return new PlaymeshFileSystemWritableFileStream(result.writerId);
    }

    get [Symbol.toStringTag]() { return "FileSystemFileHandle"; }
  }

  class PlaymeshFileSystemDirectoryHandle extends PlaymeshFileSystemHandle {
    async getFileHandle(name, options = {}) {
      return wrapFileSystemHandle(await fileSystemRequest("getChild", {
        id: this._id, name: String(name), kind: "file", create: options?.create === true,
      }));
    }

    async getDirectoryHandle(name, options = {}) {
      return wrapFileSystemHandle(await fileSystemRequest("getChild", {
        id: this._id, name: String(name), kind: "directory", create: options?.create === true,
      }));
    }

    async removeEntry(name, options = {}) {
      await fileSystemRequest("remove", {
        id: this._id, name: String(name), recursive: options?.recursive === true,
      });
    }

    async resolve(possibleDescendant) {
      if (!(possibleDescendant instanceof PlaymeshFileSystemHandle)) return null;
      return fileSystemRequest("resolve", { id: this._id, otherId: possibleDescendant._id });
    }

    async *entries() {
      let cursor = null;
      do {
        const result = await fileSystemRequest("list", {
          id: this._id,
          ...(cursor == null ? {} : { cursor }),
        });
        for (const descriptor of result.items || []) {
          const handle = wrapFileSystemHandle(descriptor);
          yield [handle.name, handle];
        }
        cursor = Number.isInteger(result.cursor) ? result.cursor : null;
      } while (cursor != null);
    }

    async *keys() { for await (const [name] of this.entries()) yield name; }
    async *values() { for await (const [, handle] of this.entries()) yield handle; }
    [Symbol.asyncIterator]() { return this.values(); }
    get [Symbol.toStringTag]() { return "FileSystemDirectoryHandle"; }
  }

  class PlaymeshFileSystemWritableFileStream {
    constructor(writerId) {
      this._writerId = writerId;
      this._tail = Promise.resolve();
      this._closed = false;
    }

    _enqueue(operation) {
      if (this._closed) return Promise.reject(new DOMException("可写流已关闭", "InvalidStateError"));
      const result = this._tail.then(operation);
      this._tail = result.catch(() => {});
      return result;
    }

    async _writeBytes(bytes) {
      for (let offset = 0; offset < bytes.length; offset += PLAYMESH_FILE_TRANSFER_CHUNK) {
        const chunk = bytes.subarray(offset, offset + PLAYMESH_FILE_TRANSFER_CHUNK);
        await fileSystemRequest("write", {
          writerId: this._writerId,
          data: bytesToBase64(chunk),
        });
      }
    }

    write(data) {
      return this._enqueue(async () => {
        if (data && typeof data === "object" && typeof data.type === "string") {
          if (data.type === "seek") return this._seekNow(data.position);
          if (data.type === "truncate") return this._truncateNow(data.size);
          if (data.type !== "write") throw new TypeError("未知写入命令");
          if (data.position != null) await this._seekNow(data.position);
          data = data.data;
        }
        await this._writeBytes(await bytesForFileSystemWrite(data));
      });
    }

    _seekNow(position) {
      if (!Number.isSafeInteger(position) || position < 0) throw new TypeError("position 必须是非负安全整数");
      return fileSystemRequest("seek", { writerId: this._writerId, position });
    }
    seek(position) { return this._enqueue(() => this._seekNow(position)); }

    _truncateNow(size) {
      if (!Number.isSafeInteger(size) || size < 0) throw new TypeError("size 必须是非负安全整数");
      return fileSystemRequest("truncate", { writerId: this._writerId, size });
    }
    truncate(size) { return this._enqueue(() => this._truncateNow(size)); }

    close() {
      if (this._closed) return Promise.reject(new DOMException("可写流已关闭", "InvalidStateError"));
      this._closed = true;
      return this._tail.then(() => fileSystemRequest("closeWritable", { writerId: this._writerId }));
    }

    abort() {
      if (this._closed) return Promise.reject(new DOMException("可写流已关闭", "InvalidStateError"));
      this._closed = true;
      return this._tail.then(() => fileSystemRequest("abortWritable", { writerId: this._writerId }));
    }

    get [Symbol.toStringTag]() { return "FileSystemWritableFileStream"; }
  }

  function wrapFileSystemHandle(descriptor) {
    if (!descriptor || typeof descriptor.id !== "string") {
      throw new DOMException("宿主返回了无效的文件句柄", "UnknownError");
    }
    return descriptor.kind === "directory"
      ? new PlaymeshFileSystemDirectoryHandle(descriptor)
      : new PlaymeshFileSystemFileHandle(descriptor);
  }

  function installFileSystemPicker(name, implementation) {
    try {
      Object.defineProperty(global, name, {
        value: implementation, configurable: true, enumerable: true, writable: true,
      });
    } catch (_) {
      global[name] = implementation;
    }
  }

  if (nativeSender() !== null) {
    installFileSystemPicker("showOpenFilePicker", async (options) => {
      const descriptors = await fileSystemRequest("pickOpen", normalizeFilePickerOptions(options, "open"));
      return descriptors.map(wrapFileSystemHandle);
    });
    installFileSystemPicker("showSaveFilePicker", async (options) =>
      wrapFileSystemHandle(await fileSystemRequest("pickSave", normalizeFilePickerOptions(options, "save")))
    );
    installFileSystemPicker("showDirectoryPicker", async (options) =>
      wrapFileSystemHandle(await fileSystemRequest("pickDirectory", normalizeFilePickerOptions(options, "directory")))
    );
  }
''',
);

final class _AppFileSystemAccessFeature implements _AppSdkCommandFeature {
  static const _commands = <String, String>{
    'app.fileSystem.pickOpen': 'pickOpen',
    'app.fileSystem.pickSave': 'pickSave',
    'app.fileSystem.pickDirectory': 'pickDirectory',
    'app.fileSystem.stat': 'stat',
    'app.fileSystem.read': 'read',
    'app.fileSystem.createWritable': 'createWritable',
    'app.fileSystem.write': 'write',
    'app.fileSystem.seek': 'seek',
    'app.fileSystem.truncate': 'truncate',
    'app.fileSystem.closeWritable': 'closeWritable',
    'app.fileSystem.abortWritable': 'abortWritable',
    'app.fileSystem.list': 'list',
    'app.fileSystem.getChild': 'getChild',
    'app.fileSystem.remove': 'remove',
    'app.fileSystem.same': 'same',
    'app.fileSystem.resolve': 'resolve',
  };

  @override
  SdkSourceFragment get source => appFileSystemAccessSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => _commands.keys.toSet();

  @override
  Future<Object?> execute(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    final nativeCommand = _commands[command.name];
    if (nativeCommand == null) throw StateError('未注册的文件系统命令: ${command.name}');
    if (nativeCommand.startsWith('pick') && !context.consumeUserActivation()) {
      throw const SdkCommandException('not_allowed', '文件或目录选择必须由用户操作直接发起');
    }
    try {
      return await context.fileSystemAccessHost.execute(
        nativeCommand,
        command.payload,
      );
    } on PlaymeshFileSystemAccessException catch (error, stackTrace) {
      throw SdkCommandException(
        error.code,
        error.message,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }
}
