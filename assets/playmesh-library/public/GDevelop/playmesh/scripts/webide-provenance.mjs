import { createHash, randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import {
  lstat,
  open,
  readFile,
  rename,
  rm,
  stat,
} from 'node:fs/promises';
import path from 'node:path';

import {
  assertManifestMatchesWebIdeLock,
  collectOutputRecordsFromSourceTree,
  listRegularFiles,
  sha256Bytes,
  validateSourcePolicyOutputManifest,
  verifyBidirectionalOverlayOutput,
  verifyOutputManifestFreezeState,
  verifyOverlayTreeDigest,
  verifyRecordedSourcePolicyOutputs,
} from './source-policy-verifier-lib.mjs';

export const BUILD_PROVENANCE_ENTRY = 'playmesh-build-provenance.json';
export const INTEGRATION_MARKER_ENTRY = 'playmesh-integration.json';
export const BUILD_PROVENANCE_SCHEMA_VERSION = 1;
export const INTEGRATION_MARKER_SCHEMA_VERSION = 3;

const sha256Pattern = /^[a-f0-9]{64}$/;
const gitCommitPattern = /^[a-f0-9]{40}$/;
const upstreamTagPattern = /^v\d+\.\d+\.\d+$/;
const upstreamVersionPattern = /^\d+\.\d+\.\d+$/;
const officialLibGdCommitSourcePattern =
  /^https:\/\/s3\.amazonaws\.com\/gdevelop-gdevelop\.js\/master\/commit\/[a-f0-9]{40}$/;
const compareText = (left, right) =>
  left < right ? -1 : left > right ? 1 : 0;

const baseProvenanceKeys = Object.freeze([
  'policyRevision',
  'upstreamTag',
  'upstreamCommit',
  'upstreamSourceArchiveSha256',
  'sourcePolicyManifestSha256',
  'sourcePolicyOverlayTreeSha256',
  'sourcePolicyGeneratedFilesSha256',
  'sourcePolicyPatchedOfficialFilesSha256',
  'patchedSourceSha256',
]);

export const buildProvenanceKeys = Object.freeze([
  'schemaVersion',
  'artifactKind',
  ...baseProvenanceKeys,
  'buildTreeSha256',
  'libGdProvenance',
  'sourcePolicyScript',
  'buildAuditScript',
]);

export const integrationMarkerKeys = Object.freeze([
  'schemaVersion',
  'artifactKind',
  ...baseProvenanceKeys,
  'buildTreeSha256',
  'preparedTreeSha256',
  'libGdProvenance',
  'sourcePolicyScript',
  'buildAuditScript',
  'packagePolicyScript',
]);

const libGdProvenanceKeys = Object.freeze([
  'kind',
  'source',
  'upstreamVersion',
  'files',
  'userDecision',
]);
const libGdFileRecordKeys = Object.freeze(['sha256', 'size']);
const libGdFileNames = Object.freeze(['libGD.js', 'libGD.wasm']);

const exactKeys = (value, expectedKeys, label) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort(compareText);
  const expected = [...expectedKeys].sort(compareText);
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    throw new TypeError(`${label} must contain exactly: ${expected.join(', ')}`);
  }
  return value;
};

const assertSha256 = (value, label) => {
  if (typeof value !== 'string' || !sha256Pattern.test(value)) {
    throw new TypeError(`${label} must be a lowercase SHA-256 digest`);
  }
  return value;
};

const parseLibGdFileRecord = (value, label) => {
  exactKeys(value, libGdFileRecordKeys, label);
  assertSha256(value.sha256, `${label} sha256`);
  if (!Number.isSafeInteger(value.size) || value.size <= 0) {
    throw new TypeError(`${label} size must be a positive safe integer`);
  }
  return Object.freeze({ sha256: value.sha256, size: value.size });
};

export const parseLibGdProvenance = (
  source,
  label = 'libGD provenance'
) => {
  const value = exactKeys(
    typeof source === 'string' || Buffer.isBuffer(source)
      ? parseJson(source, label)
      : source,
    libGdProvenanceKeys,
    label
  );
  const isLegacyException =
    value.kind === 'approved-legacy-prepared-exception';
  const isOfficialExactCommit =
    value.kind === 'official-exact-commit-artifact';
  if (!isLegacyException && !isOfficialExactCommit) {
    throw new TypeError(
      `${label} kind must be approved-legacy-prepared-exception or official-exact-commit-artifact`
    );
  }
  if (isLegacyException) {
    const isWindowsAbsolute =
      typeof value.source === 'string' &&
      (/^[A-Za-z]:[\\/]/.test(value.source) || /^\\\\/.test(value.source));
    const isPosixAbsolute =
      typeof value.source === 'string' && path.posix.isAbsolute(value.source);
    if (!isWindowsAbsolute && !isPosixAbsolute) {
      throw new TypeError(`${label} source must be an absolute canonical path`);
    }
    // `path.win32.isAbsolute('/mnt/...')` is also true. Select by syntax so a
    // canonical WSL path is never normalized into backslashes.
    const pathApi = isWindowsAbsolute ? path.win32 : path.posix;
    if (pathApi.normalize(value.source) !== value.source) {
      throw new TypeError(`${label} source must be an absolute canonical path`);
    }
  } else if (
    typeof value.source !== 'string' ||
    !officialLibGdCommitSourcePattern.test(value.source)
  ) {
    throw new TypeError(
      `${label} source must be an exact official GDevelop commit artifact URL`
    );
  }
  if (!upstreamVersionPattern.test(value.upstreamVersion || '')) {
    throw new TypeError(`${label} upstreamVersion is invalid`);
  }
  exactKeys(value.files, libGdFileNames, `${label} files`);
  const files = Object.freeze(
    Object.fromEntries(
      libGdFileNames.map(fileName => [
        fileName,
        parseLibGdFileRecord(
          value.files[fileName],
          `${label} files.${fileName}`
        ),
      ])
    )
  );
  const expectedUserDecision = isLegacyException ? 'B' : 'not-required';
  if (value.userDecision !== expectedUserDecision) {
    throw new TypeError(
      `${label} userDecision must be ${expectedUserDecision}`
    );
  }
  return Object.freeze({
    kind: value.kind,
    source: value.source,
    upstreamVersion: value.upstreamVersion,
    files,
    userDecision: value.userDecision,
  });
};

export const verifyLibGdRuntimePairBytes = ({
  javascriptBytes,
  wasmBytes,
  label = 'libGD runtime pair',
}) => {
  if (!(javascriptBytes instanceof Uint8Array) || javascriptBytes.byteLength <= 0) {
    throw new TypeError(`${label} libGD.js must be non-empty bytes`);
  }
  if (!(wasmBytes instanceof Uint8Array) || wasmBytes.byteLength <= 0) {
    throw new TypeError(`${label} libGD.wasm must be non-empty bytes`);
  }
  const javascriptSource = Buffer.from(
    javascriptBytes.buffer,
    javascriptBytes.byteOffset,
    javascriptBytes.byteLength
  ).toString('utf8');
  if (!/wasmBinaryFile\s*=\s*["']libGD\.wasm["']/.test(javascriptSource)) {
    throw new Error(`${label} JavaScript does not bind libGD.wasm`);
  }
  let wasmModule;
  try {
    wasmModule = new WebAssembly.Module(
      Buffer.from(wasmBytes.buffer, wasmBytes.byteOffset, wasmBytes.byteLength)
    );
  } catch (error) {
    throw new Error(`${label} WebAssembly compilation failed: ${error.message}`);
  }
  const referencedExports = new Set(
    [...javascriptSource.matchAll(/Module\["asm"\]\["([^"]+)"\]/g)].map(
      match => match[1]
    )
  );
  if (referencedExports.size === 0) {
    throw new Error(`${label} JavaScript has no Emscripten runtime bindings`);
  }
  const wasmExports = new Set(
    WebAssembly.Module.exports(wasmModule).map(entry => entry.name)
  );
  const missingExports = [...referencedExports].filter(
    name => !wasmExports.has(name)
  );
  if (missingExports.length > 0) {
    throw new Error(
      `${label} JS/WASM pair mismatch; missing export ${missingExports[0]}`
    );
  }
  const wasmImports = WebAssembly.Module.imports(wasmModule);
  if (wasmImports.length > 0) {
    const libraryStart = javascriptSource.indexOf('var asmLibraryArg={');
    const libraryEnd = javascriptSource.indexOf(
      'var asm=createWasm()',
      libraryStart
    );
    if (libraryStart === -1 || libraryEnd === -1) {
      throw new Error(`${label} JavaScript has no Emscripten import library`);
    }
    const librarySource = javascriptSource.slice(libraryStart, libraryEnd);
    const missingImports = wasmImports.filter(
      entry =>
        entry.module !== 'a' ||
        !librarySource.includes(`${JSON.stringify(entry.name)}:`)
    );
    if (missingImports.length > 0) {
      throw new Error(
        `${label} JS/WASM pair mismatch; missing import ${
          missingImports[0].module
        }.${missingImports[0].name}`
      );
    }
  }
  return Object.freeze({
    referencedExportCount: referencedExports.size,
    wasmExportCount: wasmExports.size,
    wasmImportCount: wasmImports.length,
  });
};

export const verifyLibGdBytesAgainstProvenance = ({
  provenance: rawProvenance,
  javascriptBytes,
  wasmBytes,
  label = 'libGD',
}) => {
  const provenance = parseLibGdProvenance(
    rawProvenance,
    `${label} provenance`
  );
  const inputs = {
    'libGD.js': javascriptBytes,
    'libGD.wasm': wasmBytes,
  };
  for (const fileName of libGdFileNames) {
    const bytes = inputs[fileName];
    if (!(bytes instanceof Uint8Array) || bytes.byteLength <= 0) {
      throw new Error(`${label} ${fileName} is missing or empty`);
    }
    const record = provenance.files[fileName];
    if (bytes.byteLength !== record.size) {
      throw new Error(
        `${label} ${fileName} size mismatch. Expected ${record.size}, got ${bytes.byteLength}`
      );
    }
    const sha256 = sha256Bytes(
      Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength)
    );
    if (sha256 !== record.sha256) {
      throw new Error(
        `${label} ${fileName} SHA-256 mismatch. Expected ${record.sha256}, got ${sha256}`
      );
    }
  }
  const pairing = verifyLibGdRuntimePairBytes({
    javascriptBytes,
    wasmBytes,
    label,
  });
  return Object.freeze({ provenance, pairing });
};

export const verifyLibGdFilesAgainstProvenance = async ({
  directory,
  provenance,
  label = 'libGD',
}) =>
  verifyLibGdBytesAgainstProvenance({
    provenance,
    javascriptBytes: await readFile(path.join(directory, 'libGD.js')),
    wasmBytes: await readFile(path.join(directory, 'libGD.wasm')),
    label,
  });

const parseJson = (bytes, label) => {
  try {
    return JSON.parse(Buffer.isBuffer(bytes) ? bytes.toString('utf8') : bytes);
  } catch (error) {
    throw new TypeError(`${label} is not valid JSON: ${error.message}`);
  }
};

export const parseProvenanceWebIdeLock = source => {
  const lock =
    typeof source === 'string' || Buffer.isBuffer(source)
      ? parseJson(source, 'webide-lock.json')
      : source;
  if (!lock || typeof lock !== 'object' || Array.isArray(lock)) {
    throw new TypeError('webide-lock.json must be an object');
  }
  if (lock.schemaVersion !== 1) {
    throw new TypeError('webide-lock schemaVersion must be 1');
  }
  const upstream = lock.upstream;
  if (!upstream || typeof upstream !== 'object' || Array.isArray(upstream)) {
    throw new TypeError('webide-lock upstream is missing');
  }
  if (!upstreamTagPattern.test(upstream.tag || '')) {
    throw new TypeError('webide-lock upstream.tag must use vMAJOR.MINOR.PATCH');
  }
  if (!gitCommitPattern.test(upstream.commit || '')) {
    throw new TypeError('webide-lock upstream.commit must be a Git commit SHA');
  }
  assertSha256(
    upstream.sourceArchiveSha256,
    'webide-lock upstream.sourceArchiveSha256'
  );
  if (!Number.isSafeInteger(lock.playmeshRevision) || lock.playmeshRevision <= 0) {
    throw new TypeError('webide-lock playmeshRevision must be positive');
  }
  return Object.freeze({
    lock,
    tag: upstream.tag,
    commit: upstream.commit,
    sourceArchiveSha256: upstream.sourceArchiveSha256,
    revision: lock.playmeshRevision,
  });
};

const canonicalRecordSetDigest = (label, entries) => {
  const normalized = entries
    .map(entry => ({
      relativePath: entry.relativePath,
      ...('upstreamGitBlobSha' in entry
        ? { upstreamGitBlobSha: entry.upstreamGitBlobSha }
        : {}),
      postPatchSha256: entry.postPatchSha256,
    }))
    .sort((left, right) => compareText(left.relativePath, right.relativePath));
  return sha256Bytes(
    Buffer.from(
      `playmesh-gdevelop-${label}-v1\0${JSON.stringify(normalized)}`,
      'utf8'
    )
  );
};

const deriveBaseProvenance = ({ lock, sourcePolicy }) => {
  const sourcePolicyGeneratedFilesSha256 = canonicalRecordSetDigest(
    'generated-files',
    sourcePolicy.manifest.generatedFiles
  );
  const sourcePolicyPatchedOfficialFilesSha256 = canonicalRecordSetDigest(
    'patched-official-files',
    sourcePolicy.manifest.patchedOfficialFiles
  );
  const base = {
    policyRevision: lock.revision,
    upstreamTag: lock.tag,
    upstreamCommit: lock.commit,
    upstreamSourceArchiveSha256: lock.sourceArchiveSha256,
    sourcePolicyManifestSha256: sourcePolicy.sha256,
    sourcePolicyOverlayTreeSha256: sourcePolicy.manifest.overlay.treeSha256,
    sourcePolicyGeneratedFilesSha256,
    sourcePolicyPatchedOfficialFilesSha256,
  };
  return Object.freeze({
    ...base,
    patchedSourceSha256: sha256Bytes(
      Buffer.from(
        `playmesh-gdevelop-patched-source-v1\0${JSON.stringify(base)}`,
        'utf8'
      )
    ),
  });
};

export const loadFrozenProvenanceContext = async ({
  lockPath,
  sourcePolicyManifestPath,
}) => {
  const [lockBytes, sourcePolicyBytes] = await Promise.all([
    readFile(lockPath),
    readFile(sourcePolicyManifestPath),
  ]);
  const lock = parseProvenanceWebIdeLock(lockBytes);
  const sourcePolicy = Object.freeze({
    manifest: validateSourcePolicyOutputManifest(
      parseJson(sourcePolicyBytes, 'source-policy-output-manifest.json')
    ),
    sha256: sha256Bytes(sourcePolicyBytes),
  });
  verifyOutputManifestFreezeState({ manifest: sourcePolicy.manifest });
  assertManifestMatchesWebIdeLock({
    manifest: sourcePolicy.manifest,
    lock: lock.lock,
  });
  return Object.freeze({
    lock,
    sourcePolicy,
    base: deriveBaseProvenance({ lock, sourcePolicy }),
  });
};

export const hashFile = async filePath => {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(filePath)) hash.update(chunk);
  return hash.digest('hex');
};

export const verifyPatchedSourceInputs = async ({
  context,
  sourceArchivePath,
  sourceRoot,
  overlayDirectory,
}) => {
  const archiveMetadata = await stat(sourceArchivePath);
  if (!archiveMetadata.isFile() || archiveMetadata.size <= 0) {
    throw new Error('Official GDevelop source archive is missing or empty');
  }
  const archiveSha256 = await hashFile(sourceArchivePath);
  if (archiveSha256 !== context.lock.sourceArchiveSha256) {
    throw new Error(
      `Official GDevelop source archive SHA-256 mismatch. Expected ${
        context.lock.sourceArchiveSha256
      }, got ${archiveSha256}`
    );
  }
  await verifyOverlayTreeDigest({
    manifest: context.sourcePolicy.manifest,
    overlayDirectory,
  });
  const records = await collectOutputRecordsFromSourceTree({
    manifest: context.sourcePolicy.manifest,
    sourceRoot,
  });
  verifyRecordedSourcePolicyOutputs({
    manifest: context.sourcePolicy.manifest,
    ...records,
  });
  await verifyBidirectionalOverlayOutput({
    overlayDirectory,
    sourceRoot,
    generatedFiles: context.sourcePolicy.manifest.generatedFiles,
  });
  return Object.freeze({
    archiveSha256,
    patchedSourceSha256: context.base.patchedSourceSha256,
  });
};

const uint64 = value => {
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64BE(BigInt(value));
  return bytes;
};

const compareWebIdeTreePaths = (left, right) => {
  const leftSegments = left.split('/');
  const rightSegments = right.split('/');
  const commonLength = Math.min(leftSegments.length, rightSegments.length);
  for (let index = 0; index < commonLength; index += 1) {
    if (leftSegments[index] < rightSegments[index]) return -1;
    if (leftSegments[index] > rightSegments[index]) return 1;
  }
  return leftSegments.length - rightSegments.length;
};

export const computeWebIdeTreeDigestFromRecords = async records => {
  if (!Array.isArray(records)) {
    throw new TypeError('WebIDE tree records must be an array');
  }
  const normalized = records.map((record, index) => {
    const relativePath = record?.relativePath;
    if (
      typeof relativePath !== 'string' ||
      !relativePath ||
      relativePath.includes('\\') ||
      relativePath.startsWith('/') ||
      relativePath !== relativePath.normalize('NFC') ||
      path.posix.normalize(relativePath) !== relativePath ||
      relativePath
        .split('/')
        .some(segment => !segment || segment === '.' || segment === '..')
    ) {
      throw new TypeError(`Invalid WebIDE tree path at record ${index}`);
    }
    if (typeof record.readBytes !== 'function') {
      throw new TypeError(`WebIDE tree record ${relativePath} needs readBytes`);
    }
    return { relativePath, readBytes: record.readBytes };
  });
  normalized.sort((left, right) =>
    compareWebIdeTreePaths(left.relativePath, right.relativePath)
  );
  for (let index = 1; index < normalized.length; index += 1) {
    if (normalized[index - 1].relativePath === normalized[index].relativePath) {
      throw new TypeError(
        `Duplicate WebIDE tree path: ${normalized[index].relativePath}`
      );
    }
  }
  const hash = createHash('sha256');
  hash.update('playmesh-gdevelop-webide-tree-v1\0', 'utf8');
  for (const record of normalized) {
    const relativePathBytes = Buffer.from(record.relativePath, 'utf8');
    const rawBytes = await record.readBytes();
    if (!(rawBytes instanceof Uint8Array)) {
      throw new TypeError(
        `WebIDE tree reader must return bytes: ${record.relativePath}`
      );
    }
    const bytes = Buffer.from(
      rawBytes.buffer,
      rawBytes.byteOffset,
      rawBytes.byteLength
    );
    hash.update(uint64(relativePathBytes.byteLength));
    hash.update(relativePathBytes);
    hash.update(uint64(bytes.byteLength));
    hash.update(bytes);
  }
  return Object.freeze({
    sha256: hash.digest('hex'),
    fileCount: normalized.length,
  });
};

const normalizeExcludedPaths = paths => {
  const output = new Set();
  for (const value of paths || []) {
    if (
      typeof value !== 'string' ||
      !value ||
      value.includes('\\') ||
      value.startsWith('/') ||
      path.posix.normalize(value) !== value ||
      value.split('/').some(segment => !segment || segment === '.' || segment === '..')
    ) {
      throw new TypeError(`Invalid excluded provenance path: ${value}`);
    }
    output.add(value);
  }
  return output;
};

export const computeWebIdeTreeDigest = async ({
  directory,
  excludedRelativePaths = [],
}) => {
  const excluded = normalizeExcludedPaths(excludedRelativePaths);
  const files = (await listRegularFiles(directory)).filter(
    file => !excluded.has(file.relativePath)
  );
  return computeWebIdeTreeDigestFromRecords(
    files.map(file => ({
      relativePath: file.relativePath,
      readBytes: () => readFile(file.absolutePath),
    }))
  );
};

const assertBaseProvenance = ({ value, context, label }) => {
  for (const key of baseProvenanceKeys) {
    if (value[key] !== context.base[key]) {
      throw new Error(`${label} ${key} differs from the frozen release context`);
    }
  }
  if (
    value.libGdProvenance.upstreamVersion !==
    context.base.upstreamTag.slice(1)
  ) {
    throw new Error(
      `${label} libGdProvenance upstreamVersion differs from the frozen release context`
    );
  }
};

export const parseBuildProvenance = (source, label = 'Build provenance') => {
  const value = exactKeys(
    typeof source === 'string' || Buffer.isBuffer(source)
      ? parseJson(source, label)
      : source,
    buildProvenanceKeys,
    label
  );
  if (value.schemaVersion !== BUILD_PROVENANCE_SCHEMA_VERSION) {
    throw new TypeError(`${label} has an unsupported schemaVersion`);
  }
  if (value.artifactKind !== 'playmesh-gdevelop-webide-build') {
    throw new TypeError(`${label} has an invalid artifactKind`);
  }
  if (!Number.isSafeInteger(value.policyRevision) || value.policyRevision <= 0) {
    throw new TypeError(`${label} policyRevision must be positive`);
  }
  if (!upstreamTagPattern.test(value.upstreamTag || '')) {
    throw new TypeError(`${label} upstreamTag is invalid`);
  }
  if (!gitCommitPattern.test(value.upstreamCommit || '')) {
    throw new TypeError(`${label} upstreamCommit is invalid`);
  }
  for (const key of [
    'upstreamSourceArchiveSha256',
    'sourcePolicyManifestSha256',
    'sourcePolicyOverlayTreeSha256',
    'sourcePolicyGeneratedFilesSha256',
    'sourcePolicyPatchedOfficialFilesSha256',
    'patchedSourceSha256',
    'buildTreeSha256',
  ]) {
    assertSha256(value[key], `${label} ${key}`);
  }
  const libGdProvenance = parseLibGdProvenance(
    value.libGdProvenance,
    `${label} libGdProvenance`
  );
  if (
    value.sourcePolicyScript !== 'playmesh/scripts/apply-source-policy.mjs' ||
    value.buildAuditScript !==
      'playmesh/tests/test-production-build-audit.mjs'
  ) {
    throw new TypeError(`${label} names an unexpected policy script`);
  }
  return Object.freeze({ ...value, libGdProvenance });
};

export const createBuildProvenance = ({
  context,
  buildTreeSha256,
  libGdProvenance,
}) =>
  parseBuildProvenance({
    schemaVersion: BUILD_PROVENANCE_SCHEMA_VERSION,
    artifactKind: 'playmesh-gdevelop-webide-build',
    ...context.base,
    buildTreeSha256,
    libGdProvenance,
    sourcePolicyScript: 'playmesh/scripts/apply-source-policy.mjs',
    buildAuditScript: 'playmesh/tests/test-production-build-audit.mjs',
  });

export const verifyBuildProvenance = async ({
  buildDirectory,
  context,
}) => {
  const provenancePath = path.join(buildDirectory, BUILD_PROVENANCE_ENTRY);
  const metadata = await lstat(provenancePath);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size <= 0) {
    throw new Error('Build provenance is missing, empty or not a regular file');
  }
  const value = parseBuildProvenance(
    await readFile(provenancePath),
    'Build provenance'
  );
  assertBaseProvenance({ value, context, label: 'Build provenance' });
  const tree = await computeWebIdeTreeDigest({
    directory: buildDirectory,
    excludedRelativePaths: [BUILD_PROVENANCE_ENTRY],
  });
  if (value.buildTreeSha256 !== tree.sha256) {
    throw new Error(
      `Build provenance is stale. Expected tree ${value.buildTreeSha256}, got ${
        tree.sha256
      }`
    );
  }
  await verifyLibGdFilesAgainstProvenance({
    directory: buildDirectory,
    provenance: value.libGdProvenance,
    label: 'Audited build libGD',
  });
  return Object.freeze({ value, tree });
};

export const writeJsonAtomically = async (targetPath, value) => {
  const absoluteTarget = path.resolve(targetPath);
  const temporaryPath = `${absoluteTarget}.tmp-${process.pid}-${randomUUID()}`;
  let handle;
  try {
    handle = await open(temporaryPath, 'wx');
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, 'utf8');
    await handle.sync();
    await handle.close();
    handle = null;
    await rename(temporaryPath, absoluteTarget);
  } finally {
    if (handle) await handle.close();
    await rm(temporaryPath, { force: true });
  }
};

export const writeBuildProvenance = async ({
  buildDirectory,
  context,
  libGdProvenance,
}) => {
  const tree = await computeWebIdeTreeDigest({
    directory: buildDirectory,
    excludedRelativePaths: [BUILD_PROVENANCE_ENTRY],
  });
  const value = createBuildProvenance({
    context,
    buildTreeSha256: tree.sha256,
    libGdProvenance,
  });
  await writeJsonAtomically(
    path.join(buildDirectory, BUILD_PROVENANCE_ENTRY),
    value
  );
  return Object.freeze({ value, tree });
};

export const parseIntegrationMarker = (
  source,
  label = 'Prepared WebIDE integration marker'
) => {
  const value = exactKeys(
    typeof source === 'string' || Buffer.isBuffer(source)
      ? parseJson(source, label)
      : source,
    integrationMarkerKeys,
    label
  );
  if (value.schemaVersion !== INTEGRATION_MARKER_SCHEMA_VERSION) {
    throw new TypeError(`${label} has an unsupported schemaVersion`);
  }
  if (value.artifactKind !== 'playmesh-gdevelop-webide-prepared') {
    throw new TypeError(`${label} has an invalid artifactKind`);
  }
  if (!Number.isSafeInteger(value.policyRevision) || value.policyRevision <= 0) {
    throw new TypeError(`${label} policyRevision must be positive`);
  }
  if (!upstreamTagPattern.test(value.upstreamTag || '')) {
    throw new TypeError(`${label} upstreamTag is invalid`);
  }
  if (!gitCommitPattern.test(value.upstreamCommit || '')) {
    throw new TypeError(`${label} upstreamCommit is invalid`);
  }
  for (const key of [
    'upstreamSourceArchiveSha256',
    'sourcePolicyManifestSha256',
    'sourcePolicyOverlayTreeSha256',
    'sourcePolicyGeneratedFilesSha256',
    'sourcePolicyPatchedOfficialFilesSha256',
    'patchedSourceSha256',
    'buildTreeSha256',
    'preparedTreeSha256',
  ]) {
    assertSha256(value[key], `${label} ${key}`);
  }
  const libGdProvenance = parseLibGdProvenance(
    value.libGdProvenance,
    `${label} libGdProvenance`
  );
  if (
    value.sourcePolicyScript !== 'playmesh/scripts/apply-source-policy.mjs' ||
    value.buildAuditScript !==
      'playmesh/tests/test-production-build-audit.mjs' ||
    value.packagePolicyScript !== 'playmesh/scripts/prepare-webide.mjs'
  ) {
    throw new TypeError(`${label} names an unexpected policy script`);
  }
  return Object.freeze({ ...value, libGdProvenance });
};

export const createIntegrationMarker = ({
  context,
  buildProvenance,
  preparedTreeSha256,
}) => {
  assertBaseProvenance({
    value: buildProvenance,
    context,
    label: 'Build provenance',
  });
  return parseIntegrationMarker({
    schemaVersion: INTEGRATION_MARKER_SCHEMA_VERSION,
    artifactKind: 'playmesh-gdevelop-webide-prepared',
    ...context.base,
    buildTreeSha256: buildProvenance.buildTreeSha256,
    preparedTreeSha256,
    libGdProvenance: buildProvenance.libGdProvenance,
    sourcePolicyScript: 'playmesh/scripts/apply-source-policy.mjs',
    buildAuditScript: 'playmesh/tests/test-production-build-audit.mjs',
    packagePolicyScript: 'playmesh/scripts/prepare-webide.mjs',
  });
};

export const verifyPreparedProvenanceRecords = ({
  context,
  buildProvenanceSource,
  integrationMarkerSource,
  location = 'Prepared WebIDE',
}) => {
  const buildProvenance = parseBuildProvenance(
    buildProvenanceSource,
    `${location} build provenance`
  );
  assertBaseProvenance({
    value: buildProvenance,
    context,
    label: `${location} build provenance`,
  });
  const marker = parseIntegrationMarker(
    integrationMarkerSource,
    `${location} integration marker`
  );
  assertBaseProvenance({
    value: marker,
    context,
    label: `${location} integration marker`,
  });
  if (marker.buildTreeSha256 !== buildProvenance.buildTreeSha256) {
    throw new Error(`${location} marker does not bind its build provenance`);
  }
  if (
    JSON.stringify(marker.libGdProvenance) !==
    JSON.stringify(buildProvenance.libGdProvenance)
  ) {
    throw new Error(`${location} marker does not bind its libGD provenance`);
  }
  return Object.freeze({ marker, buildProvenance });
};

export const verifyPreparedProvenance = async ({
  preparedDirectory,
  context,
}) => {
  const buildProvenancePath = path.join(
    preparedDirectory,
    BUILD_PROVENANCE_ENTRY
  );
  const integrationMarkerPath = path.join(
    preparedDirectory,
    INTEGRATION_MARKER_ENTRY
  );
  const [buildMetadata, markerMetadata] = await Promise.all([
    lstat(buildProvenancePath),
    lstat(integrationMarkerPath),
  ]);
  for (const [label, metadata] of [
    ['build provenance', buildMetadata],
    ['integration marker', markerMetadata],
  ]) {
    if (
      !metadata.isFile() ||
      metadata.isSymbolicLink() ||
      metadata.size <= 0 ||
      metadata.size > 64 * 1024
    ) {
      throw new Error(
        `Prepared WebIDE ${label} is missing, invalid or too large`
      );
    }
  }
  const { marker, buildProvenance } = verifyPreparedProvenanceRecords({
    context,
    buildProvenanceSource: await readFile(buildProvenancePath),
    integrationMarkerSource: await readFile(integrationMarkerPath),
  });
  const tree = await computeWebIdeTreeDigest({
    directory: preparedDirectory,
    excludedRelativePaths: [INTEGRATION_MARKER_ENTRY],
  });
  if (marker.preparedTreeSha256 !== tree.sha256) {
    throw new Error(
      `Prepared WebIDE provenance is stale. Expected tree ${
        marker.preparedTreeSha256
      }, got ${tree.sha256}`
    );
  }
  await verifyLibGdFilesAgainstProvenance({
    directory: preparedDirectory,
    provenance: marker.libGdProvenance,
    label: 'Prepared WebIDE libGD',
  });
  return Object.freeze({ marker, buildProvenance, tree });
};
