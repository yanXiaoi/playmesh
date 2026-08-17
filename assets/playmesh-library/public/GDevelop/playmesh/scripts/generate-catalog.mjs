import { gzipSync } from 'node:zlib';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import {
  access,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
} from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import {
  describeCatalogFile,
  generateExamplesIndexFromTree,
  generateExtensionsIndex,
  readAndHashFile,
  sha256Bytes,
  writeCanonicalJson,
} from './catalog-generator-lib.mjs';
import { generateCatalogTranslationSidecar } from './catalog-translation-lib.mjs';
import { verifyGeneratedCatalogDirectory } from './catalog-verifier-lib.mjs';

const execFileAsync = promisify(execFile);

const parseArguments = argv => {
  const values = new Map();
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key || !key.startsWith('--') || !value) {
      throw new Error(`无效参数：${key || '<empty>'}`);
    }
    values.set(key, value);
  }
  return values;
};

const argumentsMap = parseArguments(process.argv);
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(scriptDirectory, '..');
const lockPath = path.join(playmeshDirectory, 'catalog-lock.json');
const outputDirectory = path.resolve(
  argumentsMap.get('--output') || path.join(playmeshDirectory, 'catalog', 'generated')
);
const extensionsRoot = argumentsMap.get('--extensions-root');
const examplesRoot = argumentsMap.get('--examples-root');
const examplesTreePath = argumentsMap.get('--examples-tree');
const translationProvider =
  argumentsMap.get('--translation-provider') ||
  process.env.PLAYMESH_CATALOG_TRANSLATION_PROVIDER ||
  'auto';
const translationTargets = (
  argumentsMap.get('--translation-targets') || 'zh-CN'
)
  .split(',')
  .map(value => value.trim())
  .filter(Boolean);
const translationCachePath = path.resolve(
  argumentsMap.get('--translation-cache') ||
    path.join(
      playmeshDirectory,
      '..',
      '..',
      '..',
      '..',
      '..',
      'work',
      'gdevelop-catalog-translation-cache.v1.json'
    )
);
const translationTimeoutMs = Number(
  argumentsMap.get('--translation-timeout-ms') || 15000
);

if (!extensionsRoot || !examplesRoot || !examplesTreePath) {
  throw new Error(
    '用法：node generate-catalog.mjs ' +
      '--extensions-root <固定扩展源码目录> ' +
      '--examples-root <固定示例源码目录> ' +
      '--examples-tree <固定 commit 的 Git tree JSON> ' +
      '[--output <catalog目录>] ' +
      '[--translation-provider <auto|microsoft|google|none>] ' +
      '[--translation-targets <zh-CN>] ' +
      '[--translation-cache <持久缓存文件>]'
  );
}
if (
  !Number.isSafeInteger(translationTimeoutMs) ||
  translationTimeoutMs < 1000 ||
  translationTimeoutMs > 120000
) {
  throw new Error('--translation-timeout-ms 必须是 1000 到 120000 的整数。');
}

const assertSafeOutput = output => {
  const parsed = path.parse(output);
  if (output === parsed.root || output === playmeshDirectory) {
    throw new Error(`拒绝清理不安全的目录：${output}`);
  }
  const relative = path.relative(playmeshDirectory, output);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`目录制品必须位于 Playmesh GDevelop 目录内：${output}`);
  }
};
assertSafeOutput(outputDirectory);

const lock = JSON.parse(await readFile(lockPath, 'utf8'));
const webIdeLock = JSON.parse(
  await readFile(path.join(playmeshDirectory, 'webide-lock.json'), 'utf8')
);
if (
  lock.schemaVersion !== 1 ||
  webIdeLock.schemaVersion !== 1 ||
  lock.engine.version !== webIdeLock.upstream.tag.slice(1) ||
  lock.engine.tag !== webIdeLock.upstream.tag ||
  lock.engine.commit !== webIdeLock.upstream.commit
) {
  throw new Error('catalog-lock.json 与当前 GDevelop 内核不匹配。');
}

const startedAt = Date.now();
const resolvedExtensionsRoot = path.resolve(extensionsRoot);
const resolvedExamplesRoot = path.resolve(examplesRoot);
const runGitAt = async (root, args) =>
  (await execFileAsync('git', ['-C', root, ...args], {
    encoding: 'utf8',
    maxBuffer: 4 * 1024 * 1024,
  })).stdout.trim();
const readGitBlobAt = async (root, objectName) => {
  const { stdout } = await execFileAsync(
    'git',
    ['-C', root, 'cat-file', 'blob', objectName],
    {
      encoding: null,
      maxBuffer: Math.max(
        lock.limits.exampleResourceBytes,
        lock.limits.extensionBytes
      ),
    }
  );
  return Buffer.isBuffer(stdout) ? stdout : Buffer.from(stdout);
};
const digestBytes = bytes => ({
  bytes,
  byteLength: bytes.byteLength,
  sha256: sha256Bytes(bytes),
});
const extensionHead = await runGitAt(resolvedExtensionsRoot, ['rev-parse', 'HEAD']);
const extensionRootTree = await runGitAt(resolvedExtensionsRoot, ['rev-parse', 'HEAD^{tree}']);
const extensionRemote = (await runGitAt(resolvedExtensionsRoot, ['remote', 'get-url', 'origin'])).replace(/\/$/, '');
if (
  extensionHead !== lock.sources.extensions.commit ||
  extensionRootTree !== lock.sources.extensions.rootTreeSha ||
  extensionRemote !== lock.sources.extensions.remote.replace(/\/$/, '')
) {
  throw new Error('扩展源码 checkout 未匹配 catalog-lock.json 的官方 remote/commit/root tree。');
}
const exampleHead = await runGitAt(resolvedExamplesRoot, ['rev-parse', 'HEAD']);
const exampleRootTree = await runGitAt(resolvedExamplesRoot, ['rev-parse', 'HEAD^{tree}']);
const exampleRemote = (await runGitAt(resolvedExamplesRoot, ['remote', 'get-url', 'origin'])).replace(/\/$/, '');
if (
  exampleHead !== lock.sources.examples.commit ||
  exampleRootTree !== lock.sources.examples.rootTreeSha ||
  exampleRemote !== lock.sources.examples.remote.replace(/\/$/, '')
) {
  throw new Error('示例源码 checkout 未匹配 catalog-lock.json 的官方 remote/commit/root tree。');
}

const examplesTree = JSON.parse(
  await readFile(path.resolve(examplesTreePath), 'utf8')
);
if (!examplesTree || examplesTree.truncated || !Array.isArray(examplesTree.tree)) {
  throw new Error('示例 Git tree 缺失、被截断或格式错误。');
}
const treeMetadata = {
  repository: lock.sources.examples.repository,
  commit: lock.sources.examples.commit,
  rootTreeSha: lock.sources.examples.rootTreeSha,
  entryCount: examplesTree.tree.length,
};

const exampleContentSha256ByPath = new Map();
for (const entry of examplesTree.tree) {
  if (!entry || entry.type !== 'blob' || !String(entry.path || '').startsWith('examples/')) {
    continue;
  }
  const sourceFile = path.resolve(
    resolvedExamplesRoot,
    ...String(entry.path).split('/')
  );
  const relative = path.relative(resolvedExamplesRoot, sourceFile);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`示例源码路径越界：${String(entry.path)}`);
  }
  let digest = await readAndHashFile(sourceFile);
  if (digest.byteLength !== entry.size) {
    // 兼容曾经由 Windows core.autocrlf 生成的旧缓存。制品摘要必须以
    // 固定 commit 的 Git blob 原始字节为准，不能对 CRLF 工作树放宽校验。
    digest = digestBytes(await readGitBlobAt(resolvedExamplesRoot, entry.sha));
  }
  if (digest.byteLength !== entry.size) {
    throw new Error(`示例 Git blob 大小与固定 tree 不一致：${String(entry.path)}`);
  }
  exampleContentSha256ByPath.set(entry.path, digest.sha256);
}

const stagingDirectory = `${outputDirectory}.staging-${process.pid}-${Date.now()}`;
const backupDirectory = `${outputDirectory}.backup-${process.pid}-${Date.now()}`;
await mkdir(stagingDirectory, { recursive: true });

const writeCatalog = async () => {
  const extensionsIndex = await generateExtensionsIndex({
    root: resolvedExtensionsRoot,
    lock,
    readSourceFile: async filePath => {
      const relativePath = path
        .relative(resolvedExtensionsRoot, filePath)
        .split(path.sep)
        .join('/');
      if (
        !relativePath ||
        relativePath.startsWith('../') ||
        path.isAbsolute(relativePath)
      ) {
        throw new Error(`扩展源码路径越界：${filePath}`);
      }
      return digestBytes(
        await readGitBlobAt(resolvedExtensionsRoot, `HEAD:${relativePath}`)
      );
    },
  });
  const examplesResult = generateExamplesIndexFromTree({
    tree: examplesTree,
    lock,
    contentSha256ByPath: exampleContentSha256ByPath,
  });

  const extensionsIndexResult = await writeCanonicalJson(
    path.join(stagingDirectory, 'extensions-index.json'),
    extensionsIndex
  );
  const examplesIndexResult = await writeCanonicalJson(
    path.join(stagingDirectory, 'examples-index.json'),
    examplesResult.index
  );
  const localizationDescriptors = {};
  const translationStats = [];
  for (const targetLocale of translationTargets) {
    const translation = await generateCatalogTranslationSidecar({
      extensionsIndex,
      examplesIndex: examplesResult.index,
      catalogRevision: lock.catalogRevision,
      targetLocale,
      cachePath: translationCachePath,
      providerMode: translationProvider,
      timeoutMs: translationTimeoutMs,
    });
    const locale = translation.sidecar.locale;
    const relativePath = `i18n/${locale}.json`;
    const result = await writeCanonicalJson(
      path.join(stagingDirectory, ...relativePath.split('/')),
      translation.sidecar
    );
    localizationDescriptors[locale] = describeCatalogFile(relativePath, result);
    translationStats.push(translation.stats);
  }
  const extensionsManifest = {
    schemaVersion: 1,
    kind: 'extensions',
    catalogRevision: lock.catalogRevision,
    engine: lock.engine,
    source: lock.sources.extensions,
    index: describeCatalogFile('extensions-index.json', extensionsIndexResult),
    counts: {
      extensions: extensionsIndex.headers.length,
      behaviors: extensionsIndex.behavior.headers.length,
    },
  };
  const examplesManifest = {
    schemaVersion: 1,
    kind: 'examples',
    catalogRevision: lock.catalogRevision,
    engine: lock.engine,
    source: lock.sources.examples,
    treeMetadata,
    index: describeCatalogFile('examples-index.json', examplesIndexResult),
    counts: {
      examples: examplesResult.index.headers.length,
      unavailableExamples: examplesResult.index.unavailable.length,
    },
  };
  const extensionsManifestResult = await writeCanonicalJson(
    path.join(stagingDirectory, 'extensions-manifest.v1.json'),
    extensionsManifest
  );
  const examplesManifestResult = await writeCanonicalJson(
    path.join(stagingDirectory, 'examples-manifest.v1.json'),
    examplesManifest
  );
  const manifest = {
    schemaVersion: 1,
    catalogRevision: lock.catalogRevision,
    engine: lock.engine,
    sources: lock.sources,
    limits: lock.limits,
    treeMetadata,
    features: {
      extensions: describeCatalogFile(
        'extensions-manifest.v1.json',
        extensionsManifestResult
      ),
      examples: describeCatalogFile(
        'examples-manifest.v1.json',
        examplesManifestResult
      ),
      localizations: localizationDescriptors,
    },
    counts: {
      extensions: extensionsIndex.headers.length,
      behaviors: extensionsIndex.behavior.headers.length,
      examples: examplesResult.index.headers.length,
      unavailableExamples: examplesResult.index.unavailable.length,
    },
  };
  await writeCanonicalJson(
    path.join(stagingDirectory, 'catalog-manifest.json'),
    manifest
  );
  return { manifest, translationStats };
};

const calculateManifestSizes = async directory => {
  let files = 0;
  let bytes = 0;
  let gzipBytes = 0;
  const visit = async currentDirectory => {
    for (const entry of await readdir(currentDirectory, { withFileTypes: true })) {
      const entryPath = path.join(currentDirectory, entry.name);
      if (entry.isDirectory()) {
        await visit(entryPath);
      } else if (entry.isFile() && entry.name.endsWith('.json')) {
        const content = await readFile(entryPath);
        files += 1;
        bytes += content.byteLength;
        gzipBytes += gzipSync(content, { level: 9 }).byteLength;
      }
    }
  };
  await visit(directory);
  return { files, bytes, gzipBytes };
};

let previousOutputMoved = false;
try {
  const { manifest, translationStats } = await writeCatalog();
  await verifyGeneratedCatalogDirectory(stagingDirectory);
  const sizes = await calculateManifestSizes(stagingDirectory);
  try {
    await access(outputDirectory);
    await rename(outputDirectory, backupDirectory);
    previousOutputMoved = true;
  } catch (error) {
    if (!error || error.code !== 'ENOENT') throw error;
  }
  await rename(stagingDirectory, outputDirectory);
  if (previousOutputMoved) {
    await rm(backupDirectory, { recursive: true, force: true });
  }
  const elapsedMs = Date.now() - startedAt;
  process.stdout.write(
    `${JSON.stringify(
      {
        outputDirectory,
        elapsedMs,
        counts: manifest.counts,
        translations: translationStats,
        manifestFiles: sizes.files,
        manifestBytes: sizes.bytes,
        manifestGzipBytes: sizes.gzipBytes,
      },
      null,
      2
    )}\n`
  );
} catch (error) {
  await rm(stagingDirectory, { recursive: true, force: true });
  if (previousOutputMoved) {
    try {
      await rename(backupDirectory, outputDirectory);
    } catch (restoreError) {
      process.stderr.write(
        `恢复旧目录制品失败：${String(restoreError.message || restoreError)}\n`
      );
    }
  }
  throw error;
}
