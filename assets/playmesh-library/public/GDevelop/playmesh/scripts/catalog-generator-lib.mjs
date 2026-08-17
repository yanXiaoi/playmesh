import { createHash } from 'node:crypto';
import {
  mkdir,
  readFile,
  readdir,
  stat,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';

const utf8Decoder = new TextDecoder('utf-8', { fatal: true });

export const sha256Bytes = bytes =>
  createHash('sha256').update(bytes).digest('hex');

export const readAndHashFile = async filePath => {
  const bytes = await readFile(filePath);
  return {
    bytes,
    byteLength: bytes.byteLength,
    sha256: sha256Bytes(bytes),
  };
};

const parseVersion = value => {
  const match = String(value || '').trim().match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!match) throw new Error(`无效语义版本：${String(value)}`);
  return match.slice(1).map(Number);
};

export const compareVersions = (left, right) => {
  const leftParts = parseVersion(left);
  const rightParts = parseVersion(right);
  for (let index = 0; index < 3; index++) {
    if (leftParts[index] !== rightParts[index]) {
      return leftParts[index] < rightParts[index] ? -1 : 1;
    }
  }
  return 0;
};

export const isEngineVersionCompatible = (engineVersion, constraint) => {
  if (!constraint || !String(constraint).trim()) return true;
  const match = String(constraint)
    .trim()
    .match(/^(>=|>|<=|<|=|\^|~)?\s*(\d+\.\d+\.\d+)$/);
  if (!match) return false;
  const operator = match[1] || '=';
  const expected = match[2];
  const comparison = compareVersions(engineVersion, expected);
  if (operator === '>=') return comparison >= 0;
  if (operator === '>') return comparison > 0;
  if (operator === '<=') return comparison <= 0;
  if (operator === '<') return comparison < 0;
  if (operator === '=') return comparison === 0;
  if (operator === '^') {
    const [major] = parseVersion(expected);
    const [engineMajor] = parseVersion(engineVersion);
    return engineMajor === major && comparison >= 0;
  }
  if (operator === '~') {
    const [major, minor] = parseVersion(expected);
    const [engineMajor, engineMinor] = parseVersion(engineVersion);
    return engineMajor === major && engineMinor === minor && comparison >= 0;
  }
  return false;
};

const normalizeTags = tags => {
  const values = Array.isArray(tags) ? tags : String(tags || '').split(',');
  return [...new Set(values.map(tag => String(tag).trim().toLowerCase()).filter(Boolean))];
};

const sanitizeInlineIcon = extension => {
  for (const candidate of [extension.previewIconUrl, extension.iconUrl]) {
    if (typeof candidate === 'string' && candidate.startsWith('data:image/')) {
      return candidate;
    }
  }
  return '';
};

const filterPublicFunctions = functions =>
  (functions || []).filter(
    eventsFunction =>
      !eventsFunction.private &&
      (eventsFunction.fullName || eventsFunction.functionType === 'ActionWithOperator')
  );

const formatFunction = (allFunctions, eventsFunction) => {
  if (eventsFunction.functionType === 'ActionWithOperator') {
    const getter = allFunctions.find(
      other => other.name === eventsFunction.getterName
    );
    return {
      name: eventsFunction.name,
      fullName: getter ? getter.fullName : eventsFunction.fullName,
      description: `Change ${
        getter
          ? getter.description || getter.fullName
          : eventsFunction.description || eventsFunction.fullName
      }`,
      functionType: 'Action',
    };
  }
  if (eventsFunction.functionType === 'ExpressionAndCondition') {
    return {
      name: eventsFunction.name,
      fullName: eventsFunction.fullName,
      description: `Compare ${eventsFunction.description || ''}`,
      functionType: 'Condition',
    };
  }
  return {
    name: eventsFunction.name,
    fullName: eventsFunction.fullName,
    description: eventsFunction.description || '',
    functionType: eventsFunction.functionType,
  };
};

const collectRequiredBehaviorTypes = (
  extension,
  behavior,
  collected = []
) => {
  for (const descriptor of behavior.propertyDescriptors || []) {
    if (descriptor.type !== 'Behavior') continue;
    const requiredType = descriptor.extraInformation && descriptor.extraInformation[0];
    if (!requiredType || collected.includes(requiredType)) continue;
    collected.push(requiredType);
    const ownPrefix = `${extension.name}::`;
    if (!requiredType.startsWith(ownPrefix)) continue;
    const requiredName = requiredType.slice(ownPrefix.length);
    const requiredBehavior = (extension.eventsBasedBehaviors || []).find(
      candidate => candidate.name === requiredName
    );
    if (!requiredBehavior) {
      throw new Error(
        `扩展 ${extension.name} 缺少行为依赖 ${requiredType}`
      );
    }
    collectRequiredBehaviorTypes(extension, requiredBehavior, collected);
  }
  return collected;
};

const rawUrl = (repository, commit, sourcePath) =>
  `https://raw.githubusercontent.com/${repository}/${commit}/${sourcePath
    .split('/')
    .map(segment => encodeURIComponent(segment))
    .join('/')}`;

const createArtifact = ({
  id,
  kind,
  repository,
  commit,
  rootTreeSha,
  sourcePath,
  declaredBytes,
  gitBlobOid,
  sha256,
  mediaType,
}) => ({
  id,
  kind,
  repository,
  commit,
  rootTreeSha,
  path: sourcePath,
  url: rawUrl(repository, commit, sourcePath),
  ...(Number.isSafeInteger(declaredBytes) ? { declaredBytes } : {}),
  ...(gitBlobOid ? { gitBlobOid } : {}),
  sha256,
  mediaType,
});

const readJson = async (filePath, readSourceFile = readAndHashFile) => {
  const { bytes, ...digest } = await readSourceFile(filePath);
  let value;
  try {
    value = JSON.parse(utf8Decoder.decode(bytes));
  } catch (error) {
    throw new Error(`无法解析 JSON ${filePath}: ${String(error.message || error)}`);
  }
  return { value, ...digest };
};

const listJsonFiles = async directory =>
  (await readdir(directory, { withFileTypes: true }))
    .filter(entry => entry.isFile() && entry.name.endsWith('.json'))
    .map(entry => entry.name)
    .sort((left, right) => left.localeCompare(right, 'en'));

export const generateExtensionsIndex = async ({
  root,
  lock,
  readSourceFile = readAndHashFile,
}) => {
  const source = lock.sources.extensions;
  const extensions = [];
  for (const tier of ['reviewed', 'community']) {
    const tierDirectory = path.join(root, 'extensions', tier);
    for (const filename of await listJsonFiles(tierDirectory)) {
      const sourcePath = `extensions/${tier}/${filename}`;
      const { value, byteLength, sha256 } = await readJson(
        path.join(tierDirectory, filename),
        readSourceFile
      );
      if (!value || typeof value !== 'object') {
        throw new Error(`扩展正文不是对象：${sourcePath}`);
      }
      if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(value.name || '')) {
        throw new Error(`扩展名不安全：${sourcePath}`);
      }
      if (`${value.name}.json` !== filename) {
        throw new Error(`扩展名和文件名不一致：${sourcePath}`);
      }
      if (!isEngineVersionCompatible(lock.engine.version, value.gdevelopVersion)) {
        throw new Error(
          `扩展 ${value.name} 不兼容 GDevelop ${lock.engine.version}：${
            value.gdevelopVersion || '未知约束'
          }`
        );
      }
      extensions.push({
        tier,
        value,
        artifact: createArtifact({
          id: `extension:${value.name}`,
          kind: 'extension',
          repository: source.repository,
          commit: source.commit,
          rootTreeSha: source.rootTreeSha,
          sourcePath,
          declaredBytes: byteLength,
          sha256,
          mediaType: 'application/json',
        }),
      });
    }
  }
  extensions.sort((left, right) =>
    left.value.name.localeCompare(right.value.name, 'en')
  );
  const byName = new Map(extensions.map(item => [item.value.name, item]));
  for (const { value } of extensions) {
    for (const dependency of value.requiredExtensions || []) {
      const dependencyItem = byName.get(dependency.extensionName);
      if (!dependencyItem) {
        throw new Error(
          `扩展 ${value.name} 的依赖不存在：${dependency.extensionName}`
        );
      }
      if (
        compareVersions(
          dependencyItem.value.version,
          dependency.extensionVersion
        ) < 0
      ) {
        throw new Error(
          `扩展 ${value.name} 的依赖版本不足：${dependency.extensionName} ${dependency.extensionVersion}`
        );
      }
    }
  }

  const headers = [];
  const behaviorHeaders = [];
  const artifacts = {};
  for (const { tier, value: extension, artifact } of extensions) {
    const publicBehaviors = (extension.eventsBasedBehaviors || []).filter(
      behavior => !behavior.private
    );
    const publicObjects = (extension.eventsBasedObjects || []).filter(
      object => !object.private
    );
    const publicFunctions = filterPublicFunctions(extension.eventsFunctions);
    const previewIconUrl = sanitizeInlineIcon(extension);
    const common = {
      tier,
      authorIds: extension.authorIds || [],
      extensionNamespace: extension.extensionNamespace || '',
      fullName: extension.fullName || extension.name,
      name: extension.name,
      version: extension.version,
      gdevelopVersion: extension.gdevelopVersion || '',
      url: artifact.url,
      headerUrl: `playmesh-catalog-header://${encodeURIComponent(extension.name)}`,
      tags: normalizeTags(extension.tags),
      category: extension.category || 'General',
      previewIconUrl,
      changelog: (extension.changelog || []).map(({ version, breaking }) => ({
        version,
        breaking: Array.isArray(breaking) ? breaking.join('\n') : breaking,
      })),
      requiredExtensions: extension.requiredExtensions || [],
    };
    const header = {
      ...common,
      shortDescription: extension.shortDescription || '',
      description: Array.isArray(extension.description)
        ? extension.description.join('\n')
        : extension.description || '',
      iconUrl: previewIconUrl,
      eventsBasedBehaviorsCount: publicBehaviors.length,
      eventsFunctionsCount: publicFunctions.length,
      helpPath: extension.helpPath || `/extensions/${extension.name}`,
      artifactId: artifact.id,
    };
    if (tier === 'reviewed') {
      header.eventsBasedBehaviors = publicBehaviors.map(behavior => ({
        description: behavior.description || '',
        fullName: behavior.fullName || behavior.name,
        name: behavior.name,
        objectType: behavior.objectType,
        eventsFunctions: filterPublicFunctions(behavior.eventsFunctions).map(
          eventsFunction => formatFunction(behavior.eventsFunctions, eventsFunction)
        ),
      }));
      header.eventsFunctions = publicFunctions.map(eventsFunction =>
        formatFunction(extension.eventsFunctions, eventsFunction)
      );
      header.eventsBasedObjects = publicObjects.map(object => ({
        description: object.description || '',
        fullName: object.fullName || object.name,
        name: object.name,
        defaultName: object.defaultName || object.name,
        eventsFunctions: filterPublicFunctions(object.eventsFunctions).map(
          eventsFunction => formatFunction(object.eventsFunctions, eventsFunction)
        ),
      }));
    }
    headers.push(header);
    behaviorHeaders.push(
      ...publicBehaviors.map(behavior => ({
        ...common,
        extensionName: extension.name,
        name: behavior.name,
        fullName: behavior.fullName || behavior.name,
        description: behavior.description || '',
        objectType: behavior.objectType,
        allRequiredBehaviorTypes: collectRequiredBehaviorTypes(
          extension,
          behavior,
          []
        ),
        previewIconUrl: sanitizeInlineIcon(behavior) || previewIconUrl,
      }))
    );
    artifacts[artifact.id] = artifact;
  }

  const views = JSON.parse(
    await readFile(path.join(root, 'extensions', 'views.json'), 'utf8')
  );
  return {
    schemaVersion: 1,
    catalogRevision: lock.catalogRevision,
    engine: lock.engine,
    source,
    version: '0.0.1-playmesh',
    headers,
    views: {
      default: {
        firstIds: (views.default.firstExtensionIds || []).filter(id => byName.has(id)),
      },
    },
    behavior: {
      headers: behaviorHeaders,
      views: {
        default: {
          firstIds: views.default.firstBehaviorIds || [],
        },
      },
    },
    artifacts,
  };
};

const normalizeTreePath = value => {
  if (typeof value !== 'string' || !value || value.startsWith('/')) return null;
  if (value.includes('\\') || /^[a-z]+:/i.test(value)) return null;
  const segments = value.split('/');
  if (segments.some(segment => !segment || segment === '.' || segment === '..')) {
    return null;
  }
  return segments.join('/');
};

export const mediaTypeForPath = sourcePath => {
  const extension = path.extname(sourcePath).toLowerCase();
  return (
    {
      '.json': 'application/json',
      '.js': 'text/javascript',
      '.mjs': 'text/javascript',
      '.txt': 'text/plain',
      '.md': 'text/markdown',
      '.csv': 'text/csv',
      '.xml': 'application/xml',
      '.atlas': 'text/plain',
      '.fnt': 'text/plain',
      '.piskel': 'application/json',
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.webp': 'image/webp',
      '.gif': 'image/gif',
      '.svg': 'image/svg+xml',
      '.mp3': 'audio/mpeg',
      '.ogg': 'audio/ogg',
      '.wav': 'audio/wav',
      '.aac': 'audio/aac',
      '.m4a': 'audio/mp4',
      '.mp4': 'video/mp4',
      '.webm': 'video/webm',
      '.ttf': 'font/ttf',
      '.otf': 'font/otf',
      '.woff': 'font/woff',
      '.woff2': 'font/woff2',
      '.glb': 'model/gltf-binary',
      '.gltf': 'model/gltf+json',
    }[extension] || 'application/octet-stream'
  );
};

const titleFromSlug = slug =>
  slug
    .split('-')
    .filter(Boolean)
    .map(word => word.slice(0, 1).toUpperCase() + word.slice(1))
    .join(' ');

const attributionFilenamePattern = /^(?:license|copying|credits?|attribution)(?:\..+)?$/i;
const ignoredRepositoryMarkerPattern = /^IGNORED\.md$/i;

const toTreeArtifact = ({ entry, id, kind, source, sha256 }) =>
  createArtifact({
    id,
    kind,
    repository: source.repository,
    commit: source.commit,
    rootTreeSha: source.rootTreeSha,
    sourcePath: entry.path,
    declaredBytes: entry.size,
    gitBlobOid: entry.sha,
    sha256,
    mediaType: mediaTypeForPath(entry.path),
  });

const validateTreeEntry = entry => {
  const normalizedPath = normalizeTreePath(entry && entry.path);
  if (
    !normalizedPath ||
    entry.type !== 'blob' ||
    !/^[a-f0-9]{40}$/.test(entry.sha || '') ||
    !Number.isSafeInteger(entry.size) ||
    entry.size < 0
  ) {
    throw new Error(`示例 Git tree 含无效 blob：${String(entry && entry.path)}`);
  }
  return { ...entry, path: normalizedPath };
};

export const generateExamplesIndexFromTree = ({
  tree,
  lock,
  contentSha256ByPath,
}) => {
  const source = lock.sources.examples;
  if (
    !tree ||
    tree.truncated ||
    !Array.isArray(tree.tree) ||
    (tree.sha && tree.sha !== source.commit && tree.sha !== source.rootTreeSha)
  ) {
    throw new Error('示例 Git tree 缺失、被截断或不匹配锁定 commit/tree。');
  }

  const bySlug = new Map();
  const seenPaths = new Set();
  for (const rawEntry of tree.tree) {
    if (!rawEntry || rawEntry.type !== 'blob') continue;
    const entry = validateTreeEntry(rawEntry);
    if (seenPaths.has(entry.path)) throw new Error(`示例 Git tree 路径重复：${entry.path}`);
    seenPaths.add(entry.path);
    if (!entry.path.startsWith('examples/')) continue;
    // GDevelop-examples 用零字节 IGNORED.md 标记不应作为工程资源处理的目录。
    // 它不是项目、运行资源或许可正文，也不能进入要求非空的下载 artifact 集合。
    if (ignoredRepositoryMarkerPattern.test(path.posix.basename(entry.path))) {
      continue;
    }
    const segments = entry.path.split('/');
    if (segments.length < 3) continue;
    const slug = segments[1];
    if (!slug) continue;
    if (!bySlug.has(slug)) bySlug.set(slug, []);
    bySlug.get(slug).push(entry);
  }

  const headers = [];
  const unavailable = [];
  for (const [slug, entries] of [...bySlug.entries()].sort(([left], [right]) =>
    left.localeCompare(right, 'en')
  )) {
    entries.sort((left, right) => left.path.localeCompare(right.path, 'en'));
    const exampleRoot = `examples/${slug}`;
    const preferredProjectPath = `${exampleRoot}/${slug}.json`;
    const rootJsonEntries = entries.filter(entry => {
      const relativePath = entry.path.slice(exampleRoot.length + 1);
      return !relativePath.includes('/') && relativePath.endsWith('.json');
    });
    const projectEntry = entries.find(entry => entry.path === preferredProjectPath);
    if (!projectEntry) {
      unavailable.push({
        slug,
        reason: rootJsonEntries.length
          ? 'noncanonical-project-filename'
          : 'missing-project-json',
        ...(rootJsonEntries.length
          ? { projectPaths: rootJsonEntries.map(entry => entry.path) }
          : {}),
      });
      continue;
    }
    if (
      projectEntry.size < 1 ||
      projectEntry.size > lock.limits.exampleProjectBytes
    ) {
      unavailable.push({ slug, reason: 'project-too-large' });
      continue;
    }

    const files = entries.map(entry => {
      const relativePath = entry.path.slice(exampleRoot.length + 1);
      const sha256 = contentSha256ByPath && contentSha256ByPath.get(entry.path);
      if (!/^[a-f0-9]{64}$/.test(sha256 || '')) {
        throw new Error(`示例 blob 缺少固定 SHA-256：${entry.path}`);
      }
      return {
        relativePath,
        declaredBytes: entry.size,
        gitBlobOid: entry.sha,
        sha256,
        mediaType: mediaTypeForPath(relativePath),
      };
    });
    const policyFiles = files.filter(file => {
      const filename = path.posix.basename(file.relativePath);
      return (
        file.relativePath.toLowerCase() === 'readme.md' ||
        attributionFilenamePattern.test(filename)
      );
    });
    const previewFile = files.find(file =>
      /^(?:thumbnail|preview)\.(?:png|jpe?g|webp)$/i.test(file.relativePath)
    );
    const declaredRepositoryBytes = entries.reduce(
      (total, entry) => total + entry.size,
      0
    );
    headers.push({
      id: slug,
      slug,
      root: exampleRoot,
      category: 'official-examples',
      name: titleFromSlug(slug),
      shortDescription: 'GDevelop 官方示例，导入时按需下载并在本机校验。',
      description: '项目 JSON 会先下载并校验；仅下载其中实际引用的安全相对资源。',
      tags: [],
      authors: ['GDevelop community'],
      engine: lock.engine,
      gdevelopVersion: lock.engine.version,
      project: toTreeArtifact({
        entry: projectEntry,
        id: `example:${slug}:project`,
        kind: 'example-project',
        source,
        sha256: contentSha256ByPath.get(projectEntry.path),
      }),
      files,
      license: {
        status: policyFiles.length ? 'runtime-validation-required' : 'repository-default',
        defaultName: source.license,
        defaultSourceUrl: source.licenseUrl,
        documents: policyFiles,
      },
      preview: previewFile
        ? {
            ...previewFile,
            url: rawUrl(
              source.repository,
              source.commit,
              `${exampleRoot}/${previewFile.relativePath}`
            ),
          }
        : null,
      codeSizeLevel:
        projectEntry.size > 1000000
          ? 'large'
          : projectEntry.size > 250000
          ? 'medium'
          : 'small',
      declaredFileCount: files.length,
      declaredRepositoryBytes,
    });
  }

  return {
    index: {
      schemaVersion: 2,
      catalogRevision: lock.catalogRevision,
      engine: lock.engine,
      source,
      provenance: {
        repository: source.repository,
        commit: source.commit,
        rootTreeSha: source.rootTreeSha,
        treeEntryCount: tree.tree.length,
      },
      headers,
      unavailable,
      filters: {
        allTags: [],
        defaultTags: [],
        tagsTree: [],
      },
    },
  };
};

export const writeCanonicalJson = async (filePath, value) => {
  const text = `${JSON.stringify(value, null, 2)}\n`;
  const bytes = Buffer.from(text, 'utf8');
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, bytes);
  return {
    path: filePath,
    bytes: bytes.byteLength,
    sha256: sha256Bytes(bytes),
  };
};

export const describeCatalogFile = (relativePath, result) => ({
  path: relativePath.replaceAll('\\', '/'),
  bytes: result.bytes,
  sha256: result.sha256,
  mediaType: 'application/json',
});

export const directorySize = async directory => {
  let bytes = 0;
  let files = 0;
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      const nested = await directorySize(entryPath);
      bytes += nested.bytes;
      files += nested.files;
    } else if (entry.isFile()) {
      bytes += (await stat(entryPath)).size;
      files += 1;
    }
  }
  return { bytes, files };
};
