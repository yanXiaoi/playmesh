// @flow

/**
 * The portable source archive is deliberately smaller than a generic ZIP
 * importer. It accepts the layout emitted by GDevelop's desktop
 * folder-project writer: game.json, referenced split JSON files and
 * the local resources referenced by the recomposed project.
 */

// These values are conservative browser fallbacks, not a frozen product
// contract. Callers should derive a device-aware policy (for example from
// navigator.storage.estimate()) and pass it to every format/reader step.
export const PLAYMESH_PORTABLE_PROJECT_CONSERVATIVE_LIMITS = Object.freeze({
  maxArchiveBytes: 100 * 1024 * 1024,
  maxExpandedBytes: 256 * 1024 * 1024,
  maxProjectFileBytes: 32 * 1024 * 1024,
  maxSingleResourceBytes: 64 * 1024 * 1024,
  maxResourceCount: 2048,
  maxArchiveEntries: 4096,
  maxCompressionRatio: 200,
  maxPathLength: 512,
  maxPathSegmentLength: 255,
  maxJsonDepth: 512,
});

// Compatibility alias for callers that have not selected an adaptive policy.
export const PLAYMESH_PORTABLE_PROJECT_LIMITS = PLAYMESH_PORTABLE_PROJECT_CONSERVATIVE_LIMITS;

const LIMIT_KEYS = Object.freeze(
  Object.keys(PLAYMESH_PORTABLE_PROJECT_CONSERVATIVE_LIMITS)
);

export class PlaymeshProjectImportError extends Error {
  /*::
  code: string;
  details: mixed;
  */

  constructor(
    code /*: string */,
    message /*: string */,
    details /*: mixed */ = null
  ) {
    super(message);
    this.name = 'PlaymeshProjectImportError';
    this.code = code;
    this.details = details;
  }
}

const fail = (
  code /*: string */,
  message /*: string */,
  details /*: mixed */ = null
) /*: empty */ => {
  throw new PlaymeshProjectImportError(code, message, details);
};

const limitDetails = (
  limitCode /*: string */,
  actual /*: number */,
  max /*: number */,
  extra /*: ?Object */ = null
) /*: Object */ => ({ limitCode, actual, max, ...(extra || {}) });

export const resolvePortableImportLimits = (
  overrides /*: ?Object */ = null
) /*: Object */ => {
  const limits /*: any */ = {
    ...PLAYMESH_PORTABLE_PROJECT_CONSERVATIVE_LIMITS,
    ...(overrides || {}),
  };
  for (const key of LIMIT_KEYS) {
    const value = limits[key];
    const valid =
      key === 'maxCompressionRatio'
        ? typeof value === 'number' && Number.isFinite(value) && value > 0
        : Number.isSafeInteger(value) && value >= 1;
    if (!valid) {
      fail('invalid_import_limits', `portable ZIP 安全策略无效：${key}`, {
        limitCode: key,
        actual: value,
        max: null,
      });
    }
  }
  return Object.freeze(limits);
};

const requireSafeSize = (
  value /*: mixed */,
  field /*: string */,
  filename /*: string */
) /*: number */ => {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail('invalid_archive_entry', `ZIP 条目 ${filename} 的 ${field} 无效。`, {
      filename,
      field,
    });
  }
  return Number(value);
};

const isSymlinkEntry = (entry /*: any */) /*: boolean */ => {
  if (entry && entry.isSymbolicLink === true) return true;
  const directMode = entry && entry.unixMode;
  const externalAttributes = entry && entry.externalFileAttributes;
  const mode = Number.isSafeInteger(directMode)
    ? directMode
    : Number.isSafeInteger(externalAttributes)
    ? (externalAttributes >>> 16) & 0xffff
    : 0;
  return (mode & 0xf000) === 0xa000;
};

export const normalizePortableProjectPath = (
  rawPath /*: mixed */,
  options /*: ?{| directory?: boolean, limits?: Object |} */ = null
) /*: string */ => {
  const limits = resolvePortableImportLimits(options && options.limits);
  if (typeof rawPath !== 'string' || !rawPath) {
    fail('invalid_archive_path', 'ZIP 包含空路径。');
  }
  const safePath: string = (rawPath: any);
  if (safePath.includes('\\')) {
    fail('invalid_archive_path', `ZIP 路径不能包含反斜杠：${safePath}`);
  }
  if (safePath.includes(':')) {
    fail('invalid_archive_path', `ZIP 路径不能包含冒号：${safePath}`);
  }
  if (/[\u0000-\u001f\u007f]/.test(safePath)) {
    fail('invalid_archive_path', `ZIP 路径包含控制字符：${safePath}`);
  }
  if (safePath.startsWith('/') || /^[A-Za-z]:/.test(safePath)) {
    fail('invalid_archive_path', `ZIP 路径不能是绝对路径：${safePath}`);
  }

  const isDirectory = !!(options && options.directory);
  if (isDirectory !== safePath.endsWith('/')) {
    fail('invalid_archive_path', `ZIP 目录标记与路径不一致：${safePath}`);
  }
  const withoutTrailingSlash = isDirectory
    ? safePath.slice(0, safePath.length - 1)
    : safePath;
  if (!withoutTrailingSlash) {
    fail('invalid_archive_path', `ZIP 路径无效：${safePath}`);
  }
  const normalized = withoutTrailingSlash.normalize('NFC');
  if (normalized.length > limits.maxPathLength) {
    fail(
      'archive_path_too_long',
      `ZIP 路径过长：${safePath}`,
      limitDetails('maxPathLength', normalized.length, limits.maxPathLength, {
        path: safePath,
      })
    );
  }
  const segments = normalized.split('/');
  if (
    segments.some(segment => !segment || segment === '.' || segment === '..')
  ) {
    fail('invalid_archive_path', `ZIP 包含目录穿越或空路径段：${safePath}`);
  }
  const oversizedSegment = segments.find(
    segment => segment.length > limits.maxPathSegmentLength
  );
  if (oversizedSegment) {
    fail(
      'archive_path_segment_too_long',
      `ZIP 路径段过长：${safePath}`,
      limitDetails(
        'maxPathSegmentLength',
        oversizedSegment.length,
        limits.maxPathSegmentLength,
        { path: safePath }
      )
    );
  }
  return segments.join('/');
};

export const inspectPortableProjectEntries = (
  {
    archiveBytes,
    entries,
    limits: limitOverrides,
  } /*: {|
  archiveBytes: number,
  entries: Array<any>,
  limits?: Object,
|} */
) /*: any */ => {
  const limits = resolvePortableImportLimits(limitOverrides);
  if (!Number.isSafeInteger(archiveBytes) || archiveBytes < 1) {
    fail('invalid_archive', '工程 ZIP 大小无效。', { archiveBytes });
  }
  if (archiveBytes > limits.maxArchiveBytes) {
    fail(
      'archive_too_large',
      '工程 ZIP 超过当前设备的导入预算。',
      limitDetails('maxArchiveBytes', archiveBytes, limits.maxArchiveBytes)
    );
  }
  if (!Array.isArray(entries) || entries.length < 1) {
    fail('invalid_archive', '工程 ZIP 为空或无法读取。');
  }
  if (entries.length > limits.maxArchiveEntries) {
    fail(
      'too_many_archive_entries',
      '工程 ZIP 条目数量超过当前设备的导入预算。',
      limitDetails(
        'maxArchiveEntries',
        entries.length,
        limits.maxArchiveEntries
      )
    );
  }

  const files: Map<string, any> = new Map();
  const normalizedPaths: Set<string> = new Set();
  const caseFoldedPaths: Map<string, string> = new Map();
  let expandedBytes = 0;
  let compressedBytes = 0;

  for (const entry of entries) {
    if (!entry || typeof entry !== 'object') {
      fail('invalid_archive_entry', '工程 ZIP 包含无效条目。');
    }
    const filename = entry.filename;
    if (typeof filename !== 'string') {
      fail('invalid_archive_entry', '工程 ZIP 条目缺少文件名。');
    }
    if (entry.encrypted === true) {
      fail('encrypted_archive_entry', `工程 ZIP 不支持加密条目：${filename}`);
    }
    if (isSymlinkEntry(entry)) {
      fail('symlink_archive_entry', `工程 ZIP 不允许符号链接：${filename}`);
    }
    const directory = entry.directory === true;
    const normalizedPath = normalizePortableProjectPath(filename, {
      directory,
      limits,
    });
    const compressedSize = requireSafeSize(
      entry.compressedSize,
      'compressedSize',
      filename
    );
    const uncompressedSize = requireSafeSize(
      entry.uncompressedSize,
      'uncompressedSize',
      filename
    );
    if (compressedSize > archiveBytes) {
      fail(
        'invalid_archive_entry',
        `ZIP 条目压缩大小超过归档大小：${filename}`
      );
    }
    if (normalizedPaths.has(normalizedPath)) {
      fail(
        'duplicate_archive_path',
        `工程 ZIP 包含重复路径：${normalizedPath}`
      );
    }
    const caseFoldedPath = normalizedPath.toLowerCase();
    const caseCollision = caseFoldedPaths.get(caseFoldedPath);
    if (caseCollision && caseCollision !== normalizedPath) {
      fail(
        'ambiguous_archive_path',
        `工程 ZIP 包含大小写冲突路径：${caseCollision} / ${normalizedPath}`
      );
    }
    normalizedPaths.add(normalizedPath);
    caseFoldedPaths.set(caseFoldedPath, normalizedPath);

    if (directory) {
      if (compressedSize !== 0 || uncompressedSize !== 0) {
        fail('invalid_archive_entry', `ZIP 目录条目大小必须为 0：${filename}`);
      }
      continue;
    }

    if (
      normalizedPath === 'game.json' &&
      uncompressedSize > limits.maxProjectFileBytes
    ) {
      fail(
        'project_json_too_large',
        'game.json 超过当前设备的导入预算。',
        limitDetails(
          'maxProjectFileBytes',
          uncompressedSize,
          limits.maxProjectFileBytes,
          { path: normalizedPath }
        )
      );
    }
    if (
      normalizedPath !== 'game.json' &&
      uncompressedSize > limits.maxSingleResourceBytes
    ) {
      fail(
        'resource_too_large',
        `单个工程资源超过当前设备的导入预算：${normalizedPath}`,
        limitDetails(
          'maxSingleResourceBytes',
          uncompressedSize,
          limits.maxSingleResourceBytes,
          { path: normalizedPath }
        )
      );
    }

    expandedBytes += uncompressedSize;
    compressedBytes += compressedSize;
    if (
      !Number.isSafeInteger(expandedBytes) ||
      !Number.isSafeInteger(compressedBytes)
    ) {
      fail('invalid_archive_entry', '工程 ZIP 解压大小溢出。');
    }
    if (compressedBytes > archiveBytes) {
      fail('invalid_archive_entry', 'ZIP 条目压缩大小总和超过归档大小。', {
        actual: compressedBytes,
        max: archiveBytes,
      });
    }
    if (expandedBytes > limits.maxExpandedBytes) {
      fail(
        'expanded_archive_too_large',
        '工程 ZIP 解压后超过当前设备的导入预算。',
        limitDetails('maxExpandedBytes', expandedBytes, limits.maxExpandedBytes)
      );
    }
    const entryRatio = uncompressedSize / Math.max(1, compressedSize);
    if (uncompressedSize >= 1024 && entryRatio > limits.maxCompressionRatio) {
      fail(
        'suspicious_compression_ratio',
        `ZIP 条目压缩比异常：${normalizedPath}`,
        limitDetails(
          'maxCompressionRatio',
          entryRatio,
          limits.maxCompressionRatio,
          { path: normalizedPath }
        )
      );
    }

    files.set(normalizedPath, {
      path: normalizedPath,
      entry,
      compressedSize,
      uncompressedSize,
    });
  }

  if (!files.has('game.json')) {
    fail('missing_project_json', '工程 ZIP 根目录缺少 game.json。');
  }
  const archiveRatio = expandedBytes / Math.max(1, compressedBytes);
  if (
    expandedBytes >= 1024 * 1024 &&
    archiveRatio > limits.maxCompressionRatio
  ) {
    fail(
      'suspicious_compression_ratio',
      '工程 ZIP 总压缩比异常。',
      limitDetails(
        'maxCompressionRatio',
        archiveRatio,
        limits.maxCompressionRatio
      )
    );
  }
  return {
    files,
    expandedBytes,
    compressedBytes,
    archiveBytes,
    limits,
  };
};

const validateJsonValue = (
  root /*: mixed */,
  limits /*: Object */
) /*: void */ => {
  const stack = [{ value: root, depth: 0 }];
  while (stack.length) {
    const current = stack.pop();
    if (!current) break;
    const { value, depth } = current;
    if (depth > limits.maxJsonDepth) {
      fail(
        'project_json_too_deep',
        'game.json 嵌套层级超过当前设备的导入预算。',
        limitDetails('maxJsonDepth', depth, limits.maxJsonDepth)
      );
    }
    if (
      value === null ||
      typeof value === 'string' ||
      typeof value === 'boolean'
    ) {
      continue;
    }
    if (typeof value === 'number') {
      if (!Number.isFinite(value)) {
        fail('invalid_project_json', 'game.json 包含非有限数值。');
      }
      continue;
    }
    if (Array.isArray(value)) {
      value.forEach(item => stack.push({ value: item, depth: depth + 1 }));
      continue;
    }
    if (!value || typeof value !== 'object') {
      fail('invalid_project_json', 'game.json 包含不支持的字段值。');
    }
    const objectValue: { [string]: mixed } = (value: any);
    Object.keys(objectValue).forEach(key => {
      stack.push({
        value: Reflect.get(objectValue, key),
        depth: depth + 1,
      });
    });
  }
};

export const parsePortableProjectJson = (
  bytes /*: ArrayBuffer | Uint8Array */,
  limitOverrides /*: ?Object */ = null
) /*: Object */ => {
  const limits = resolvePortableImportLimits(limitOverrides);
  if (!(bytes instanceof ArrayBuffer) && !(bytes instanceof Uint8Array)) {
    fail('invalid_project_json', 'game.json 必须是字节数据。');
  }
  const byteLength = bytes.byteLength;
  if (byteLength < 1) {
    fail('invalid_project_json', 'game.json 不能为空。');
  }
  if (byteLength > limits.maxProjectFileBytes) {
    fail(
      'project_json_too_large',
      'game.json 超过当前设备的导入预算。',
      limitDetails(
        'maxProjectFileBytes',
        byteLength,
        limits.maxProjectFileBytes
      )
    );
  }
  let parsed: any = null;
  try {
    parsed = JSON.parse(
      new TextDecoder('utf-8', { fatal: true }).decode(bytes)
    );
  } catch (_) {
    fail('invalid_project_json', 'game.json 必须是有效 UTF-8 JSON。');
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    fail('invalid_project_json', 'game.json 根节点必须是对象。');
  }
  validateJsonValue(parsed, limits);
  if (!parsed.gdVersion && parsed.eventsFunctions) {
    fail('extension_document', 'game.json 是 GDevelop 扩展文件，不是工程。');
  }
  if (!parsed.gdVersion) {
    fail('unrecognized_project', 'game.json 不是 GDevelop 5 工程。');
  }
  return parsed;
};

export const parsePortableProjectPartialJson = (
  bytes /*: ArrayBuffer | Uint8Array */,
  limitOverrides /*: ?Object */ = null
) /*: Object */ => {
  const limits = resolvePortableImportLimits(limitOverrides);
  if (!(bytes instanceof ArrayBuffer) && !(bytes instanceof Uint8Array)) {
    fail('invalid_project_json', 'GDevelop 工程分片必须是字节数据。');
  }
  if (bytes.byteLength < 1 || bytes.byteLength > limits.maxProjectFileBytes) {
    fail('project_json_too_large', 'GDevelop 工程分片大小无效。');
  }
  let parsed: any = null;
  try {
    parsed = JSON.parse(
      new TextDecoder('utf-8', { fatal: true }).decode(bytes)
    );
  } catch (_) {
    fail('invalid_project_json', 'GDevelop 工程分片必须是有效 UTF-8 JSON。');
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    fail('invalid_project_json', 'GDevelop 工程分片根节点必须是对象。');
  }
  validateJsonValue(parsed, limits);
  return parsed;
};

const isExternalResource = (file /*: string */) /*: boolean */ =>
  /^(?:https?|ftp|data):/i.test(file);

export const planPortableProjectResources = (
  {
    inspectedArchive,
    projectResources,
    projectFilePaths,
    limits: limitOverrides,
  } /*: {|
  inspectedArchive: any,
  projectResources: Array<{| name: string, file: string, kind?: string |}>,
  projectFilePaths: $ReadOnlySet<string>,
  limits?: Object,
|} */
) /*: any */ => {
  const limits = resolvePortableImportLimits(
    limitOverrides || (inspectedArchive && inspectedArchive.limits)
  );
  if (!Array.isArray(projectResources)) {
    fail('invalid_project_resources', 'GDevelop 工程资源清单无效。');
  }
  if (projectResources.length > limits.maxResourceCount) {
    fail(
      'too_many_resources',
      'GDevelop 工程资源数量超过当前设备的导入预算。',
      limitDetails(
        'maxResourceCount',
        projectResources.length,
        limits.maxResourceCount
      )
    );
  }

  const localFiles: Map<string, any> = new Map();
  const externalResources: Array<any> = [];
  for (const resource of projectResources) {
    if (
      !resource ||
      typeof resource.name !== 'string' ||
      typeof resource.file !== 'string'
    ) {
      fail('invalid_project_resources', 'GDevelop 工程包含无效资源。');
    }
    const file = resource.file;
    if (/^(?:blob:|playmesh-local-resource:\/\/)/i.test(file)) {
      fail(
        'session_resource_url',
        `portable ZIP 包含无法跨会话恢复的资源：${resource.name}`
      );
    }
    if (isExternalResource(file)) {
      externalResources.push(resource);
      continue;
    }
    const normalizedPath = normalizePortableProjectPath(file, { limits });
    let planned = localFiles.get(normalizedPath);
    if (!planned) {
      const descriptor = inspectedArchive.files.get(normalizedPath);
      if (!descriptor) {
        fail('missing_resource', `工程 ZIP 缺少引用资源：${normalizedPath}`);
      }
      planned = { path: normalizedPath, descriptor, resources: [] };
      localFiles.set(normalizedPath, planned);
    }
    planned.resources.push(resource);
  }

  // The official desktop folder-project writer produces game.json and the
  // split files; Playmesh adds only locally referenced resources. ZIP directory entries
  // are removed during inspection, so any remaining undeclared file is not an
  // official portable-project artifact and is rejected.
  for (const archivePath of inspectedArchive.files.keys()) {
    if (projectFilePaths.has(archivePath)) continue;
    if (!localFiles.has(archivePath)) {
      fail(
        'unexpected_archive_file',
        `工程 ZIP 包含未声明文件：${archivePath}`
      );
    }
  }
  if (localFiles.size !== inspectedArchive.files.size - projectFilePaths.size) {
    fail(
      'resource_manifest_mismatch',
      '工程 ZIP 资源清单与 game.json 不一致。'
    );
  }
  return {
    localFiles: [...localFiles.values()],
    externalResources,
  };
};

const MIME_BY_EXTENSION: { +[extension: string]: string } = Object.freeze({
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
  svg: 'image/svg+xml',
  mp3: 'audio/mpeg',
  ogg: 'audio/ogg',
  wav: 'audio/wav',
  aac: 'audio/aac',
  mp4: 'video/mp4',
  webm: 'video/webm',
  ttf: 'font/ttf',
  otf: 'font/otf',
  woff: 'font/woff',
  woff2: 'font/woff2',
  json: 'application/json',
  gltf: 'model/gltf+json',
  glb: 'model/gltf-binary',
  xml: 'application/xml',
  fnt: 'text/plain',
  atlas: 'text/plain',
});

export const getPortableResourceMimeType = (
  filePath /*: string */
) /*: string */ => {
  const dot = filePath.lastIndexOf('.');
  const extension = dot === -1 ? '' : filePath.slice(dot + 1).toLowerCase();
  return MIME_BY_EXTENSION[extension] || 'application/octet-stream';
};
