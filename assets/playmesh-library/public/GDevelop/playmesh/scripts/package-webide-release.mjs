import { createHash, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { createReadStream } from 'node:fs';
import {
  copyFile,
  link,
  lstat,
  mkdir,
  open,
  readFile,
  readdir,
  rename,
  rm,
  stat,
} from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createDeflateRaw, inflateRawSync } from 'node:zlib';

import {
  BUILD_PROVENANCE_ENTRY,
  INTEGRATION_MARKER_ENTRY,
  computeWebIdeTreeDigestFromRecords,
  loadFrozenProvenanceContext,
  parseProvenanceWebIdeLock,
  verifyLibGdBytesAgainstProvenance,
  verifyPreparedProvenance,
  verifyPreparedProvenanceRecords,
} from './webide-provenance.mjs';
import { assertWebIdeDistributionDisclaimer } from './webide-distribution-compliance-lib.mjs';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(scriptDirectory, '..');
const repositoryRoot = path.resolve(scriptDirectory, '../../../../../..');
const defaultLockPath = path.join(playmeshDirectory, 'webide-lock.json');
const defaultSourcePolicyManifestPath = path.join(
  playmeshDirectory,
  'source-policy-output-manifest.json'
);
const defaultReleaseDirectory = path.join(
  repositoryRoot,
  'resources',
  'GDevelop'
);
const defaultManifestPath = path.join(defaultReleaseDirectory, 'update.json');
const fixedDosDate = (1 << 5) | 1;
const utf8DataDescriptorFlags = 0x0808;
const maximumZip32Value = 0xffffffff;
const maximumZip32Entries = 0xffff;
const maximumProvenanceRecordBytes = 64 * 1024;
const maximumVerifiedEntryBytes = 512 * 1024 * 1024;
const maximumVerifiedTreeBytes = 2 * 1024 * 1024 * 1024;
const requiredArchiveEntries = Object.freeze([
  'GDEVELOP-LICENSE.md',
  'THIRD_PARTY_NOTICES.md',
  'asset-manifest.json',
  'index.html',
  'libGD.js',
  'libGD.wasm',
  'manifest.json',
  'playmesh-logo.png',
  'GDJS/Runtime/libs/jshashtable.js',
  BUILD_PROVENANCE_ENTRY,
  INTEGRATION_MARKER_ENTRY,
  'playmesh/host-policy.css',
  'playmesh/host-policy.js',
  'playmesh/ai/tools.json',
  'external/playmesh-i18n/playmesh-external-editor-i18n.js',
  'external/utils/parent-editor-interface.js',
  'external/piskel/piskel-index.html',
  'external/piskel/piskel-main.js',
  'external/piskel/piskel-editor/index.html',
  'external/piskel/piskel-editor/js/lib/gif/gif.ie.worker.js',
  'external/piskel/piskel-editor/playmesh-i18n/piskel-i18n.js',
  'external/piskel/piskel-editor/playmesh-i18n/locales/en.js',
  'external/piskel/piskel-editor/playmesh-i18n/locales/zh-CN.js',
  'external/jfxr/jfxr-index.html',
  'external/jfxr/jfxr-main.js',
  'external/jfxr/jfxr-editor/index.html',
  'external/jfxr/jfxr-editor/playmesh-i18n/install.js',
  'external/jfxr/jfxr-editor/playmesh-i18n/locales/en.js',
  'external/jfxr/jfxr-editor/playmesh-i18n/locales/zh-CN.js',
  'external/yarn/yarn-index.html',
  'external/yarn/yarn-main.js',
  'external/yarn/yarn-editor/index.html',
  'external/yarn/yarn-editor/playmesh-i18n/install.js',
  'external/yarn/yarn-editor/playmesh-i18n/locales/en.js',
  'external/yarn/yarn-editor/playmesh-i18n/locales/zh-CN.js',
]);
const exactKeys = (value, expected, field) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${field} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (
    actual.length !== wanted.length ||
    actual.some((key, index) => key !== wanted[index])
  ) {
    throw new TypeError(`${field} must contain exactly: ${wanted.join(', ')}`);
  }
  return value;
};

const parseJson = (source, field) => {
  try {
    return JSON.parse(source);
  } catch (error) {
    throw new TypeError(`${field} is not valid JSON: ${error.message}`);
  }
};

export const parseWebIdeReleaseManifest = (
  source,
  { allowUnpublished = false } = {}
) => {
  const root = exactKeys(
    typeof source === 'string'
      ? parseJson(source, 'GDevelop WebIDE release manifest')
      : source,
    ['sha256', 'version', 'size', 'downloads'],
    'GDevelop WebIDE release manifest'
  );
  const version = root.version;
  if (
    typeof version !== 'string' ||
    !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(version)
  ) {
    throw new TypeError('version must use the numeric MAJOR.MINOR.PATCH form');
  }
  const sha256 = root.sha256;
  if (
    typeof sha256 !== 'string' ||
    (!allowUnpublished && !/^[a-f0-9]{64}$/.test(sha256)) ||
    (allowUnpublished && sha256 !== '' && !/^[a-f0-9]{64}$/.test(sha256))
  ) {
    throw new TypeError(
      'sha256 must be empty before packaging or 64 lowercase hexadecimal characters'
    );
  }
  const size = root.size;
  if (!Number.isSafeInteger(size) || size < (allowUnpublished ? 0 : 1)) {
    throw new TypeError(
      `size must be a ${
        allowUnpublished ? 'non-negative' : 'positive'
      } safe integer`
    );
  }
  if (!Array.isArray(root.downloads) || root.downloads.length === 0) {
    throw new TypeError('downloads must be a non-empty array');
  }
  const names = new Set();
  const downloads = root.downloads.map((rawDownload, index) => {
    const download = exactKeys(
      rawDownload,
      ['name', 'url'],
      `downloads[${index}]`
    );
    if (
      typeof download.name !== 'string' ||
      download.name.trim() !== download.name ||
      download.name.length === 0 ||
      download.name.length > 64
    ) {
      throw new TypeError(`downloads[${index}].name is invalid`);
    }
    const foldedName = download.name.toLocaleLowerCase('en-US');
    if (names.has(foldedName)) {
      throw new TypeError(
        `downloads contains duplicate name: ${download.name}`
      );
    }
    names.add(foldedName);
    if (typeof download.url !== 'string') {
      throw new TypeError(`downloads[${index}].url must be a string`);
    }
    if (allowUnpublished && download.url === '') {
      return Object.freeze({ name: download.name, url: '' });
    }
    let url;
    try {
      url = new URL(download.url);
    } catch {
      throw new TypeError(`downloads[${index}].url must be an absolute URL`);
    }
    if (url.protocol !== 'https:' || url.username || url.password) {
      throw new TypeError(
        `downloads[${index}].url must be credential-free HTTPS`
      );
    }
    return Object.freeze({ name: download.name, url: download.url });
  });
  return Object.freeze({
    sha256,
    version,
    size,
    downloads: Object.freeze(downloads),
  });
};

export const parseWebIdeReleaseLock = source => {
  const provenanceLock = parseProvenanceWebIdeLock(source);
  const lock = provenanceLock.lock;
  // 上游版本只从固定 tag 派生，避免展示字段或目录名成为第二事实源。
  const tag = provenanceLock.tag;
  const commit = provenanceLock.commit;
  const version = tag.slice(1);
  const artifactName = `GDevelop-webide-v${version}.zip`;
  const revision = provenanceLock.revision;
  if (!lock.distribution || typeof lock.distribution !== 'object') {
    throw new TypeError('webide-lock distribution is missing');
  }
  if (lock.distribution.assetName !== artifactName) {
    throw new TypeError(
      `webide-lock distribution.assetName must be ${artifactName}`
    );
  }
  return Object.freeze({
    lock,
    version,
    artifactName,
    commit,
    revision,
    sourceArchiveSha256: provenanceLock.sourceArchiveSha256,
    tag,
  });
};

const crcTable = (() => {
  const table = new Uint32Array(256);
  for (let value = 0; value < 256; value += 1) {
    let current = value;
    for (let bit = 0; bit < 8; bit += 1) {
      current = current & 1 ? 0xedb88320 ^ (current >>> 1) : current >>> 1;
    }
    table[value] = current >>> 0;
  }
  return table;
})();

const updateCrc32 = (crc, bytes) => {
  let current = crc;
  for (const byte of bytes) {
    current = crcTable[(current ^ byte) & 0xff] ^ (current >>> 8);
  }
  return current >>> 0;
};

const checkedZip32 = (value, field) => {
  if (!Number.isSafeInteger(value) || value < 0 || value > maximumZip32Value) {
    throw new RangeError(`${field} exceeds the ZIP32 limit`);
  }
  return value;
};

const writeAll = async (handle, bytes, outputState) => {
  let written = 0;
  while (written < bytes.length) {
    const result = await handle.write(
      bytes,
      written,
      bytes.length - written,
      null
    );
    if (result.bytesWritten <= 0) {
      throw new Error('Unable to make progress while writing the ZIP');
    }
    written += result.bytesWritten;
  }
  outputState.sha256.update(bytes);
  outputState.offset += bytes.length;
  checkedZip32(outputState.offset, 'ZIP byte offset');
};

const collectArchiveFiles = async (root, relativeDirectory = '') => {
  const absoluteDirectory = relativeDirectory
    ? path.join(root, ...relativeDirectory.split('/'))
    : root;
  const entries = await readdir(absoluteDirectory, { withFileTypes: true });
  entries.sort((left, right) =>
    left.name === right.name ? 0 : left.name < right.name ? -1 : 1
  );
  const files = [];
  for (const entry of entries) {
    if (entry.name.includes('/') || entry.name.includes('\\')) {
      throw new TypeError(`Unsafe archive entry name: ${entry.name}`);
    }
    if (entry.name !== entry.name.normalize('NFC')) {
      throw new TypeError(`Archive entry name is not NFC: ${entry.name}`);
    }
    const relativePath = relativeDirectory
      ? `${relativeDirectory}/${entry.name}`
      : entry.name;
    const absolutePath = path.join(root, ...relativePath.split('/'));
    const metadata = await lstat(absolutePath);
    if (metadata.isSymbolicLink()) {
      throw new TypeError(
        `Symbolic links are forbidden in WebIDE ZIP: ${relativePath}`
      );
    }
    if (metadata.isDirectory()) {
      files.push(...(await collectArchiveFiles(root, relativePath)));
    } else if (metadata.isFile()) {
      if (metadata.size > maximumZip32Value) {
        throw new RangeError(`File exceeds the ZIP32 limit: ${relativePath}`);
      }
      files.push({
        absolutePath,
        relativePath,
        size: metadata.size,
      });
    } else {
      throw new TypeError(`Unsupported WebIDE entry: ${relativePath}`);
    }
  }
  return files;
};

const localHeader = nameLength => {
  const header = Buffer.alloc(30);
  header.writeUInt32LE(0x04034b50, 0);
  header.writeUInt16LE(20, 4);
  header.writeUInt16LE(utf8DataDescriptorFlags, 6);
  header.writeUInt16LE(8, 8);
  header.writeUInt16LE(0, 10);
  header.writeUInt16LE(fixedDosDate, 12);
  header.writeUInt16LE(nameLength, 26);
  return header;
};

const dataDescriptor = ({ crc32, compressedSize, uncompressedSize }) => {
  const descriptor = Buffer.alloc(16);
  descriptor.writeUInt32LE(0x08074b50, 0);
  descriptor.writeUInt32LE(crc32, 4);
  descriptor.writeUInt32LE(compressedSize, 8);
  descriptor.writeUInt32LE(uncompressedSize, 12);
  return descriptor;
};

const centralHeader = entry => {
  const header = Buffer.alloc(46);
  header.writeUInt32LE(0x02014b50, 0);
  header.writeUInt16LE(0x031e, 4);
  header.writeUInt16LE(20, 6);
  header.writeUInt16LE(utf8DataDescriptorFlags, 8);
  header.writeUInt16LE(8, 10);
  header.writeUInt16LE(0, 12);
  header.writeUInt16LE(fixedDosDate, 14);
  header.writeUInt32LE(entry.crc32, 16);
  header.writeUInt32LE(entry.compressedSize, 20);
  header.writeUInt32LE(entry.uncompressedSize, 24);
  header.writeUInt16LE(entry.nameBytes.length, 28);
  header.writeUInt32LE((0o100644 << 16) >>> 0, 38);
  header.writeUInt32LE(entry.localOffset, 42);
  return Buffer.concat([header, entry.nameBytes]);
};

const endOfCentralDirectory = ({ entryCount, centralSize, centralOffset }) => {
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entryCount, 8);
  end.writeUInt16LE(entryCount, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(centralOffset, 16);
  return end;
};

const writeCompressedFile = async ({ file, output, outputState }) => {
  const nameBytes = Buffer.from(file.relativePath, 'utf8');
  if (nameBytes.length === 0 || nameBytes.length > 0xffff) {
    throw new RangeError(`Archive path is too long: ${file.relativePath}`);
  }
  const localOffset = outputState.offset;
  await writeAll(output, localHeader(nameBytes.length), outputState);
  await writeAll(output, nameBytes, outputState);

  let crc = 0xffffffff;
  let uncompressedSize = 0;
  let compressedSize = 0;
  const deflater = createDeflateRaw({ level: 9 });
  const compressedOutput = (async () => {
    for await (const chunk of deflater) {
      const bytes = Buffer.from(chunk);
      compressedSize += bytes.length;
      checkedZip32(compressedSize, `${file.relativePath} compressed size`);
      await writeAll(output, bytes, outputState);
    }
  })();
  try {
    for await (const chunk of createReadStream(file.absolutePath)) {
      const bytes = Buffer.from(chunk);
      crc = updateCrc32(crc, bytes);
      uncompressedSize += bytes.length;
      checkedZip32(uncompressedSize, `${file.relativePath} size`);
      if (!deflater.write(bytes)) await once(deflater, 'drain');
    }
    deflater.end();
    await compressedOutput;
  } catch (error) {
    deflater.destroy(error);
    try {
      await compressedOutput;
    } catch {
      // 原始异常保留为失败原因，输出流异常只用于结束压缩器。
    }
    throw error;
  }
  if (uncompressedSize !== file.size) {
    throw new Error(`File changed while packaging: ${file.relativePath}`);
  }
  const crc32 = (crc ^ 0xffffffff) >>> 0;
  await writeAll(
    output,
    dataDescriptor({ crc32, compressedSize, uncompressedSize }),
    outputState
  );
  return {
    nameBytes,
    crc32,
    compressedSize,
    uncompressedSize,
    localOffset,
  };
};

export const createDeterministicWebIdeZip = async ({
  preparedDirectory,
  outputPath,
  excludeSourceMaps = false,
  requiredEntries = requiredArchiveEntries,
  additionalFiles = [],
}) => {
  const preparedRoot = path.resolve(preparedDirectory);
  const outputFile = path.resolve(outputPath);
  if (!(await stat(preparedRoot)).isDirectory()) {
    throw new TypeError(`Prepared WebIDE is not a directory: ${preparedRoot}`);
  }
  const collectedFiles = [
    ...(await collectArchiveFiles(preparedRoot)),
    ...additionalFiles,
  ].sort((left, right) => left.relativePath.localeCompare(right.relativePath));
  const files = excludeSourceMaps
    ? collectedFiles.filter(file => !file.relativePath.endsWith('.map'))
    : collectedFiles;
  if (files.length === 0 || files.length > maximumZip32Entries) {
    throw new RangeError('Prepared WebIDE file count exceeds the ZIP32 limit');
  }
  const paths = new Set(files.map(file => file.relativePath));
  if (paths.size !== files.length) {
    throw new Error('Prepared WebIDE contains duplicate archive paths');
  }
  for (const required of requiredEntries) {
    if (!paths.has(required)) {
      throw new Error(`Prepared WebIDE is missing ${required}`);
    }
  }
  if (!files.some(file => file.relativePath.startsWith('GDJS/Runtime/'))) {
    throw new Error('Prepared WebIDE is missing the local GDJS Runtime');
  }
  const sourceMaps = files.filter(file => file.relativePath.endsWith('.map'));
  if (sourceMaps.length > 0) {
    throw new Error(
      `Prepared WebIDE still contains source maps: ${
        sourceMaps[0].relativePath
      }`
    );
  }

  await mkdir(path.dirname(outputFile), { recursive: true });
  const output = await open(outputFile, 'wx');
  const outputState = { offset: 0, sha256: createHash('sha256') };
  let installedBytes = 0;
  const centralEntries = [];
  try {
    for (const file of files) {
      const entry = await writeCompressedFile({
        file,
        output,
        outputState,
      });
      installedBytes += entry.uncompressedSize;
      if (!Number.isSafeInteger(installedBytes)) {
        throw new RangeError('Installed WebIDE size exceeds a safe integer');
      }
      centralEntries.push(centralHeader(entry));
    }
    const centralOffset = outputState.offset;
    for (const entry of centralEntries) {
      await writeAll(output, entry, outputState);
    }
    const centralSize = outputState.offset - centralOffset;
    await writeAll(
      output,
      endOfCentralDirectory({
        entryCount: files.length,
        centralSize: checkedZip32(centralSize, 'central directory size'),
        centralOffset: checkedZip32(centralOffset, 'central directory offset'),
      }),
      outputState
    );
    await output.sync();
    return Object.freeze({
      sha256: outputState.sha256.digest('hex'),
      size: outputState.offset,
      installedBytes,
      fileCount: files.length,
    });
  } finally {
    await output.close();
  }
};

export const packageWebIdeDevelopment = async ({
  buildDirectory,
  lockPath = defaultLockPath,
  sourcePolicyManifestPath = defaultSourcePolicyManifestPath,
  manifestPath = defaultManifestPath,
  releaseDirectory = defaultReleaseDirectory,
}) => {
  const context = await loadFrozenProvenanceContext({
    lockPath,
    sourcePolicyManifestPath,
  });
  const lock = parseWebIdeReleaseLock(context.lock.lock);
  await verifyPreparedProvenance({
    preparedDirectory: buildDirectory,
    context,
  });
  const currentManifest = parseWebIdeReleaseManifest(
    await readFile(manifestPath, 'utf8'),
    { allowUnpublished: true }
  );
  const artifactPath = path.join(releaseDirectory, lock.artifactName);
  await mkdir(releaseDirectory, { recursive: true });
  const temporaryArtifact = path.join(
    releaseDirectory,
    `.${lock.artifactName}.dev-${process.pid}-${randomUUID()}`
  );
  const backupArtifact = path.join(
    releaseDirectory,
    `.${lock.artifactName}.backup-${process.pid}-${randomUUID()}`
  );
  let artifactPublished = false;
  let backupCreated = false;
  try {
    const additionalFiles = [];
    try {
      await stat(path.join(buildDirectory, 'GDEVELOP-LICENSE.md'));
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
      const licensePath = path.resolve(
        playmeshDirectory,
        '..',
        'official',
        'LICENSE.md'
      );
      const licenseMetadata = await stat(licensePath);
      additionalFiles.push({
        absolutePath: licensePath,
        relativePath: 'GDEVELOP-LICENSE.md',
        size: licenseMetadata.size,
      });
    }
    const result = await createDeterministicWebIdeZip({
      preparedDirectory: buildDirectory,
      outputPath: temporaryArtifact,
      excludeSourceMaps: true,
      requiredEntries: requiredArchiveEntries,
      additionalFiles,
    });
    const metadata = await stat(temporaryArtifact);
    if (metadata.size !== result.size || (await hashFile(temporaryArtifact)) !== result.sha256) {
      throw new Error('Development WebIDE ZIP verification failed');
    }
    const entries = await readZipCentralDirectory(temporaryArtifact);
    const names = new Set(entries.map(entry => entry.name));
    for (const required of requiredArchiveEntries) {
      if (!names.has(required)) throw new Error(`Development ZIP is missing ${required}`);
    }
    if (!entries.some(entry => entry.name.startsWith('GDJS/Runtime/'))) {
      throw new Error('Development ZIP is missing the local GDJS Runtime');
    }
    if (entries.some(entry => entry.name.endsWith('.map'))) {
      throw new Error('Development ZIP must not contain source maps');
    }
    await verifyZipProvenance({
      archivePath: temporaryArtifact,
      entries,
      context,
    });
    try {
      const existingMetadata = await stat(artifactPath);
      if (!existingMetadata.isFile()) {
        throw new TypeError(`Release artifact target is not a file: ${artifactPath}`);
      }
      try {
        await link(artifactPath, backupArtifact);
      } catch {
        await copyFile(artifactPath, backupArtifact);
      }
      backupCreated = true;
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    await rename(temporaryArtifact, artifactPath);
    artifactPublished = true;
    await writeJsonAtomically(
      manifestPath,
      manifestJson({
        sha256: result.sha256,
        version: lock.version,
        size: result.size,
        downloads: currentManifest.downloads,
      })
    );
    if (backupCreated) {
      await rm(backupArtifact, { force: true });
      backupCreated = false;
    }
    return Object.freeze({
      ...result,
      artifactPath,
      artifactName: lock.artifactName,
      version: lock.version,
      mode: 'development-test',
    });
  } catch (error) {
    await rm(temporaryArtifact, { force: true });
    if (artifactPublished) {
      if (backupCreated) {
        await rename(backupArtifact, artifactPath);
        backupCreated = false;
      } else {
        await rm(artifactPath, { force: true });
      }
    }
    if (backupCreated) await rm(backupArtifact, { force: true });
    throw error;
  }
};

const writeJsonAtomically = async (targetPath, value) => {
  const absoluteTarget = path.resolve(targetPath);
  const temporaryPath = `${absoluteTarget}.tmp-${process.pid}-${randomUUID()}`;
  const serialized = `${JSON.stringify(value, null, 2)}\n`;
  let handle;
  let committed = false;
  try {
    handle = await open(temporaryPath, 'wx');
    await handle.writeFile(serialized, 'utf8');
    await handle.sync();
    await handle.close();
    handle = null;
    await rename(temporaryPath, absoluteTarget);
    committed = true;
  } finally {
    if (handle) await handle.close();
    if (committed) {
      // The manifest rename is the commit point. Cleanup after it must never
      // turn a successfully committed manifest into an apparent failure that
      // makes the caller roll back only the ZIP.
      try {
        await rm(temporaryPath, { force: true });
      } catch (_) {}
    } else {
      await rm(temporaryPath, { force: true });
    }
  }
};

const manifestJson = manifest => ({
  sha256: manifest.sha256,
  version: manifest.version,
  size: manifest.size,
  downloads: manifest.downloads.map(download => ({
    name: download.name,
    url: download.url,
  })),
});

export const packageWebIdeRelease = async ({
  preparedDirectory,
  lockPath = defaultLockPath,
  sourcePolicyManifestPath = defaultSourcePolicyManifestPath,
  manifestPath = defaultManifestPath,
  releaseDirectory = defaultReleaseDirectory,
  removeCommittedBackup = backupPath => rm(backupPath, { force: true }),
}) => {
  // 必须在创建临时 ZIP 或改写 update.json 前阻断任何 pending。
  const context = await loadFrozenProvenanceContext({
    lockPath,
    sourcePolicyManifestPath,
  });
  const lock = parseWebIdeReleaseLock(context.lock.lock);
  await verifyPreparedProvenance({
    preparedDirectory,
    context,
  });
  const currentManifest = parseWebIdeReleaseManifest(
    await readFile(manifestPath, 'utf8'),
    { allowUnpublished: true }
  );
  const artifactPath = path.join(releaseDirectory, lock.artifactName);
  await mkdir(releaseDirectory, { recursive: true });
  const temporaryArtifact = path.join(
    releaseDirectory,
    `.${lock.artifactName}.tmp-${process.pid}-${randomUUID()}`
  );
  const backupArtifact = path.join(
    releaseDirectory,
    `.${lock.artifactName}.backup-${process.pid}-${randomUUID()}`
  );
  let artifactPublished = false;
  let backupCreated = false;
  try {
    const result = await createDeterministicWebIdeZip({
      preparedDirectory,
      outputPath: temporaryArtifact,
    });
    // 捕获打包期间持久发生的输入变化；最终 ZIP 还会独立验证两份证明链。
    await verifyPreparedProvenance({ preparedDirectory, context });
    const temporaryMetadata = await stat(temporaryArtifact);
    if (
      temporaryMetadata.size !== result.size ||
      (await hashFile(temporaryArtifact)) !== result.sha256
    ) {
      throw new Error('Temporary WebIDE ZIP verification failed');
    }
    const temporaryEntries = await readZipCentralDirectory(temporaryArtifact);
    await verifyZipProvenance({
      archivePath: temporaryArtifact,
      entries: temporaryEntries,
      context,
    });
    try {
      const existingMetadata = await stat(artifactPath);
      if (!existingMetadata.isFile()) {
        throw new TypeError(
          `Release artifact target is not a file: ${artifactPath}`
        );
      }
      try {
        await link(artifactPath, backupArtifact);
      } catch {
        await copyFile(artifactPath, backupArtifact);
      }
      backupCreated = true;
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    // 同目录 rename 在支持的平台替换 canonical 文件；backup 只用于随后清单失败时回退。
    await rename(temporaryArtifact, artifactPath);
    artifactPublished = true;
    const nextManifest = {
      sha256: result.sha256,
      version: lock.version,
      size: result.size,
      downloads: currentManifest.downloads,
    };
    await writeJsonAtomically(manifestPath, manifestJson(nextManifest));
    if (backupCreated) {
      try {
        await removeCommittedBackup(backupArtifact);
      } catch (cleanupError) {
        process.stderr.write(
          `WebIDE release committed; retained rollback backup after cleanup failure: ${
            backupArtifact
          } (${cleanupError?.message || String(cleanupError)})\n`
        );
      }
      // ZIP and manifest are now one committed pair. A retained backup is an
      // operator-cleanup concern and must not enter the pre-commit rollback.
      backupCreated = false;
    }
    return Object.freeze({
      ...result,
      artifactPath,
      artifactName: lock.artifactName,
      version: lock.version,
    });
  } catch (error) {
    await rm(temporaryArtifact, { force: true });
    if (artifactPublished) {
      if (backupCreated) {
        try {
          await rename(backupArtifact, artifactPath);
          backupCreated = false;
        } catch (rollbackError) {
          throw new AggregateError(
            [error, rollbackError],
            `WebIDE release update failed and rollback is retained at ${backupArtifact}`
          );
        }
      } else {
        await rm(artifactPath, { force: true });
      }
    }
    if (backupCreated) await rm(backupArtifact, { force: true });
    throw error;
  }
};

const hashFile = async filePath => {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(filePath)) hash.update(chunk);
  return hash.digest('hex');
};

export const readZipCentralDirectory = async archivePath => {
  const handle = await open(archivePath, 'r');
  try {
    const metadata = await handle.stat();
    const tailLength = Math.min(metadata.size, 0xffff + 22);
    const tail = Buffer.alloc(tailLength);
    await handle.read(tail, 0, tailLength, metadata.size - tailLength);
    let endIndex = -1;
    for (let index = tail.length - 22; index >= 0; index -= 1) {
      if (tail.readUInt32LE(index) === 0x06054b50) {
        endIndex = index;
        break;
      }
    }
    if (endIndex === -1) throw new Error('ZIP end record is missing');
    const entryCount = tail.readUInt16LE(endIndex + 10);
    const centralSize = tail.readUInt32LE(endIndex + 12);
    const centralOffset = tail.readUInt32LE(endIndex + 16);
    if (
      centralOffset + centralSize > metadata.size ||
      entryCount === maximumZip32Entries
    ) {
      throw new Error('ZIP central directory is invalid or ZIP64');
    }
    const central = Buffer.alloc(centralSize);
    await handle.read(central, 0, centralSize, centralOffset);
    let offset = 0;
    const entries = [];
    const names = new Set();
    while (offset < central.length) {
      if (central.readUInt32LE(offset) !== 0x02014b50) {
        throw new Error('ZIP central directory entry is invalid');
      }
      const flags = central.readUInt16LE(offset + 8);
      const method = central.readUInt16LE(offset + 10);
      const crc32 = central.readUInt32LE(offset + 16);
      const compressedSize = central.readUInt32LE(offset + 20);
      const uncompressedSize = central.readUInt32LE(offset + 24);
      const nameLength = central.readUInt16LE(offset + 28);
      const extraLength = central.readUInt16LE(offset + 30);
      const commentLength = central.readUInt16LE(offset + 32);
      const localOffset = central.readUInt32LE(offset + 42);
      const recordLength = 46 + nameLength + extraLength + commentLength;
      if (offset + recordLength > central.length) {
        throw new Error('ZIP central directory entry is truncated');
      }
      if ((flags & 0x0800) === 0 || method !== 8) {
        throw new Error('ZIP entry must use UTF-8 Deflate');
      }
      const name = central
        .subarray(offset + 46, offset + 46 + nameLength)
        .toString('utf8');
      if (
        !name ||
        name.startsWith('/') ||
        name.includes('\\') ||
        name
          .split('/')
          .some(segment => !segment || segment === '.' || segment === '..')
      ) {
        throw new Error(`ZIP contains an unsafe path: ${name}`);
      }
      if (names.has(name))
        throw new Error(`ZIP contains duplicate path: ${name}`);
      names.add(name);
      entries.push(
        Object.freeze({
          name,
          flags,
          method,
          crc32,
          compressedSize,
          uncompressedSize,
          localOffset,
        })
      );
      offset += recordLength;
    }
    if (offset !== central.length || entries.length !== entryCount) {
      throw new Error('ZIP central directory count differs from its contents');
    }
    return Object.freeze(entries);
  } finally {
    await handle.close();
  }
};

const readExactly = async ({ handle, buffer, position, label }) => {
  let offset = 0;
  while (offset < buffer.length) {
    const { bytesRead } = await handle.read(
      buffer,
      offset,
      buffer.length - offset,
      position + offset
    );
    if (bytesRead <= 0) throw new Error(`${label} is truncated`);
    offset += bytesRead;
  }
};

export const readZipEntryBytes = async ({
  archivePath,
  entry,
  maximumBytes,
}) => {
  if (
    !Number.isSafeInteger(entry.uncompressedSize) ||
    entry.uncompressedSize < 0 ||
    entry.uncompressedSize > maximumBytes ||
    !Number.isSafeInteger(entry.compressedSize) ||
    entry.compressedSize < 0 ||
    entry.compressedSize > maximumBytes + 1024 * 1024
  ) {
    throw new Error(`ZIP entry ${entry.name} exceeds its allowed size`);
  }
  const handle = await open(archivePath, 'r');
  try {
    const localHeader = Buffer.alloc(30);
    await readExactly({
      handle,
      buffer: localHeader,
      position: entry.localOffset,
      label: `ZIP local header for ${entry.name}`,
    });
    if (localHeader.readUInt32LE(0) !== 0x04034b50) {
      throw new Error(`ZIP local header is invalid for ${entry.name}`);
    }
    const flags = localHeader.readUInt16LE(6);
    const method = localHeader.readUInt16LE(8);
    const nameLength = localHeader.readUInt16LE(26);
    const extraLength = localHeader.readUInt16LE(28);
    if (flags !== entry.flags || method !== entry.method || method !== 8) {
      throw new Error(`ZIP local metadata differs for ${entry.name}`);
    }
    const localName = Buffer.alloc(nameLength);
    await readExactly({
      handle,
      buffer: localName,
      position: entry.localOffset + 30,
      label: `ZIP local name for ${entry.name}`,
    });
    if (localName.toString('utf8') !== entry.name) {
      throw new Error(`ZIP local name differs for ${entry.name}`);
    }
    const compressed = Buffer.alloc(entry.compressedSize);
    await readExactly({
      handle,
      buffer: compressed,
      position: entry.localOffset + 30 + nameLength + extraLength,
      label: `ZIP payload for ${entry.name}`,
    });
    const bytes = inflateRawSync(compressed);
    if (bytes.byteLength !== entry.uncompressedSize) {
      throw new Error(`ZIP uncompressed size differs for ${entry.name}`);
    }
    const crc32 = (updateCrc32(0xffffffff, bytes) ^ 0xffffffff) >>> 0;
    if (crc32 !== entry.crc32) {
      throw new Error(`ZIP CRC-32 differs for ${entry.name}`);
    }
    return bytes;
  } finally {
    await handle.close();
  }
};

const computeZipWebIdeTreeDigest = async ({ archivePath, entries }) => {
  const files = entries.filter(
    entry => entry.name !== INTEGRATION_MARKER_ENTRY
  );
  const totalBytes = files.reduce(
    (total, entry) => total + entry.uncompressedSize,
    0
  );
  if (
    !Number.isSafeInteger(totalBytes) ||
    totalBytes > maximumVerifiedTreeBytes
  ) {
    throw new Error('ZIP prepared tree exceeds its verification size limit');
  }
  return computeWebIdeTreeDigestFromRecords(
    files.map(entry => ({
      relativePath: entry.name,
      readBytes: () =>
        readZipEntryBytes({
          archivePath,
          entry,
          maximumBytes: maximumVerifiedEntryBytes,
        }),
    }))
  );
};

const verifyZipProvenance = async ({
  archivePath,
  entries,
  context,
}) => {
  const buildEntry = entries.find(
    entry => entry.name === BUILD_PROVENANCE_ENTRY
  );
  const integrationEntry = entries.find(
    entry => entry.name === INTEGRATION_MARKER_ENTRY
  );
  if (!buildEntry || !integrationEntry) {
    throw new Error(
      `ZIP must contain ${BUILD_PROVENANCE_ENTRY} and ${INTEGRATION_MARKER_ENTRY}`
    );
  }
  const [buildProvenanceSource, integrationMarkerSource] = await Promise.all([
    readZipEntryBytes({
      archivePath,
      entry: buildEntry,
      maximumBytes: maximumProvenanceRecordBytes,
    }),
    readZipEntryBytes({
      archivePath,
      entry: integrationEntry,
      maximumBytes: maximumProvenanceRecordBytes,
    }),
  ]);
  const records = verifyPreparedProvenanceRecords({
    context,
    buildProvenanceSource,
    integrationMarkerSource,
    location: 'Packaged WebIDE',
  });
  const libGdJavascriptEntry = entries.find(entry => entry.name === 'libGD.js');
  const libGdWasmEntry = entries.find(entry => entry.name === 'libGD.wasm');
  if (!libGdJavascriptEntry || !libGdWasmEntry) {
    throw new Error('Packaged WebIDE is missing its recorded libGD pair');
  }
  verifyLibGdBytesAgainstProvenance({
    provenance: records.marker.libGdProvenance,
    javascriptBytes: await readZipEntryBytes({
      archivePath,
      entry: libGdJavascriptEntry,
      maximumBytes: maximumVerifiedEntryBytes,
    }),
    wasmBytes: await readZipEntryBytes({
      archivePath,
      entry: libGdWasmEntry,
      maximumBytes: maximumVerifiedEntryBytes,
    }),
    label: 'Packaged WebIDE libGD',
  });
  const tree = await computeZipWebIdeTreeDigest({ archivePath, entries });
  if (records.marker.preparedTreeSha256 !== tree.sha256) {
    throw new Error(
      `Packaged WebIDE provenance is stale. Expected tree ${
        records.marker.preparedTreeSha256
      }, got ${tree.sha256}`
    );
  }
  return Object.freeze({ ...records, tree });
};

export const verifyWebIdeRelease = async ({
  lockPath = defaultLockPath,
  sourcePolicyManifestPath = defaultSourcePolicyManifestPath,
  manifestPath = defaultManifestPath,
  releaseDirectory = defaultReleaseDirectory,
  allowPendingDownloads = false,
}) => {
  const context = await loadFrozenProvenanceContext({
    lockPath,
    sourcePolicyManifestPath,
  });
  const lock = parseWebIdeReleaseLock(context.lock.lock);
  const manifest = parseWebIdeReleaseManifest(
    await readFile(manifestPath, 'utf8'),
    { allowUnpublished: allowPendingDownloads }
  );
  if (manifest.version !== lock.version) {
    throw new Error(
      `Manifest version ${manifest.version} differs from ${lock.version}`
    );
  }
  if (!/^[a-f0-9]{64}$/.test(manifest.sha256) || manifest.size <= 0) {
    throw new Error('Packaged manifest hash and size must be final');
  }
  const artifactPath = path.join(releaseDirectory, lock.artifactName);
  const metadata = await stat(artifactPath);
  if (!metadata.isFile() || metadata.size !== manifest.size) {
    throw new Error('Manifest size differs from the final ZIP byte size');
  }
  const actualSha256 = await hashFile(artifactPath);
  if (actualSha256 !== manifest.sha256) {
    throw new Error('Manifest sha256 differs from the final ZIP');
  }
  const entries = await readZipCentralDirectory(artifactPath);
  const names = new Set(entries.map(entry => entry.name));
  for (const required of requiredArchiveEntries) {
    if (!names.has(required)) throw new Error(`ZIP is missing ${required}`);
  }
  if (!entries.some(entry => entry.name.startsWith('GDJS/Runtime/'))) {
    throw new Error('ZIP is missing the local GDJS Runtime');
  }
  if (entries.some(entry => entry.name.endsWith('.map'))) {
    throw new Error('ZIP must not contain source maps');
  }
  const noticesEntry = entries.find(
    entry => entry.name === 'THIRD_PARTY_NOTICES.md'
  );
  const notices = (
    await readZipEntryBytes({
      archivePath: artifactPath,
      entry: noticesEntry,
      maximumBytes: 16 * 1024 * 1024,
    })
  ).toString('utf8');
  assertWebIdeDistributionDisclaimer({
    notices,
    label: 'THIRD_PARTY_NOTICES.md',
    requiredLanguages: ['english'],
  });
  for (const marker of [
    'unofficial modified distribution',
    `GDevelop ${lock.version}`,
    context.lock.commit,
    'GDevelop MIT license',
    'Monaco Editor',
    'React and React DOM',
    'Fira Sans',
    'zip.js',
    'Firebase JavaScript SDK used by the WebIDE npm application — 9.0.0-beta.2',
    'Firebase JavaScript SDK vendored by the GDevelop GDJS runtime — 8.3.3',
    'DialogueTree bundled bondage.js LICENSE',
    'BBText pixi-multistyle-text byte and license evidence',
    'exact upstream code revision is unknown',
    'Playmesh brand asset provenance boundary',
    'Playmesh logo build provenance (no rights conclusion)',
    'Mechanically collected verbatim materials',
    'Webpack-emitted attribution',
  ]) {
    if (!notices.includes(marker)) {
      throw new Error(`THIRD_PARTY_NOTICES.md is missing required marker: ${marker}`);
    }
  }
  if (/\bpending\b/i.test(notices)) {
    throw new Error('THIRD_PARTY_NOTICES.md contains a pending marker');
  }
  const indexEntry = entries.find(entry => entry.name === 'index.html');
  const indexHtml = (
    await readZipEntryBytes({
      archivePath: artifactPath,
      entry: indexEntry,
      maximumBytes: 16 * 1024 * 1024,
    })
  ).toString('utf8');
  for (const marker of [
    '<!-- PLAYMESH_VISUAL_EDITOR_IDENTITY -->',
    '<title>Playmesh Visual Editor</title>',
    './playmesh-logo.png',
  ]) {
    if (!indexHtml.includes(marker)) {
      throw new Error(`Packaged index.html is missing Playmesh identity: ${marker}`);
    }
  }
  for (const forbidden of [
    '<title>GDevelop',
    'content="https://gdevelop.io"',
    'GDevelop-editor-thumbnail.png',
    "viewBox='0 0 708 563'",
  ]) {
    if (indexHtml.includes(forbidden)) {
      throw new Error(`Packaged index.html retains official product identity: ${forbidden}`);
    }
  }
  const pwaManifestEntry = entries.find(entry => entry.name === 'manifest.json');
  const pwaManifest = JSON.parse(
    (
      await readZipEntryBytes({
        archivePath: artifactPath,
        entry: pwaManifestEntry,
        maximumBytes: 1024 * 1024,
      })
    ).toString('utf8')
  );
  if (
    pwaManifest.name !== 'Playmesh Visual Editor' ||
    pwaManifest.short_name !== 'Playmesh Editor' ||
    !Array.isArray(pwaManifest.icons) ||
    !pwaManifest.icons.some(icon => icon?.src === './playmesh-logo.png') ||
    Object.hasOwn(pwaManifest, 'screenshots')
  ) {
    throw new Error('Packaged manifest.json does not have the Playmesh visual editor identity');
  }
  await verifyZipProvenance({
    archivePath: artifactPath,
    entries,
    context,
  });
  return Object.freeze({
    artifactPath,
    artifactName: lock.artifactName,
    version: lock.version,
    sha256: actualSha256,
    size: metadata.size,
    installedBytes: entries.reduce(
      (total, entry) => total + entry.uncompressedSize,
      0
    ),
    fileCount: entries.length,
    downloads: manifest.downloads,
  });
};

const parseArguments = argv => {
  if (argv.length % 2 !== 0) {
    throw new TypeError('Every command line option must have one value');
  }
  const allowed = new Set([
    '--action',
    '--prepared',
    '--lock',
    '--source-policy-manifest',
    '--manifest',
    '--release-directory',
    '--allow-pending-downloads',
  ]);
  const output = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    if (!allowed.has(name) || output.has(name)) {
      throw new TypeError(`Unknown or duplicate command line option: ${name}`);
    }
    output.set(name, argv[index + 1]);
  }
  return output;
};

const runCli = async () => {
  const argumentsMap = parseArguments(process.argv.slice(2));
  const action = argumentsMap.get('--action');
  const lockPath = argumentsMap.get('--lock') || defaultLockPath;
  const sourcePolicyManifestPath =
    argumentsMap.get('--source-policy-manifest') ||
    defaultSourcePolicyManifestPath;
  const manifestPath = argumentsMap.get('--manifest') || defaultManifestPath;
  const releaseDirectory =
    argumentsMap.get('--release-directory') || defaultReleaseDirectory;
  if (action === 'package') {
    const preparedDirectory = argumentsMap.get('--prepared');
    if (!preparedDirectory) throw new TypeError('package requires --prepared');
    const result = await packageWebIdeRelease({
      preparedDirectory,
      lockPath,
      sourcePolicyManifestPath,
      manifestPath,
      releaseDirectory,
    });
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  if (action === 'dev-package') {
    const preparedDirectory = argumentsMap.get('--prepared');
    if (!preparedDirectory) throw new TypeError('dev-package requires --prepared');
    const result = await packageWebIdeDevelopment({
      buildDirectory: preparedDirectory,
      lockPath,
      sourcePolicyManifestPath,
      manifestPath,
      releaseDirectory,
    });
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  if (action === 'verify') {
    const pending = argumentsMap.get('--allow-pending-downloads');
    if (pending !== undefined && pending !== 'true' && pending !== 'false') {
      throw new TypeError('--allow-pending-downloads must be true or false');
    }
    const result = await verifyWebIdeRelease({
      lockPath,
      sourcePolicyManifestPath,
      manifestPath,
      releaseDirectory,
      allowPendingDownloads: pending === 'true',
    });
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  throw new TypeError('--action must be dev-package, package or verify');
};

if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  await runCli();
}
