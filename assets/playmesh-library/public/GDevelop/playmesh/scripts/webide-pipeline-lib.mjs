import { createHash, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { createReadStream, existsSync } from 'node:fs';
import {
  copyFile,
  cp,
  lstat,
  mkdir,
  open,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  stat,
  statfs,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { inflateRawSync } from 'node:zlib';

import { verifyLibGdRuntimePairBytes } from './webide-provenance.mjs';

export const PIPELINE_STEPS = Object.freeze([
  'extract',
  'deps',
  'patch',
  'libgd',
  'flow',
  'test',
  'build',
  'audit',
  'prepare',
  'package',
  'verify',
]);

export const PIPELINE_COMMANDS = Object.freeze([
  'status',
  'dev-package',
  ...PIPELINE_STEPS,
  'all',
  'release-check',
]);

export const PIPELINE_PREREQUISITES = Object.freeze({
  extract: Object.freeze([]),
  deps: Object.freeze(['extract']),
  patch: Object.freeze(['extract']),
  libgd: Object.freeze(['extract']),
  flow: Object.freeze(['patch', 'deps']),
  test: Object.freeze(['patch', 'deps']),
  build: Object.freeze(['patch', 'deps', 'libgd']),
  audit: Object.freeze(['extract', 'patch', 'libgd', 'build']),
  prepare: Object.freeze(['audit']),
  package: Object.freeze([
    'extract',
    'deps',
    'patch',
    'libgd',
    'build',
    'audit',
    'prepare',
  ]),
  verify: Object.freeze(['package']),
});

// These are receipt-input edges, deliberately narrower than operational
// prerequisites. In particular deps does not inherit the extract identity,
// and patch does not inherit deps. This permits exact cross-version reuse.
export const PIPELINE_INPUT_DEPENDENCIES = Object.freeze({
  extract: Object.freeze([]),
  deps: Object.freeze([]),
  patch: Object.freeze(['extract']),
  libgd: Object.freeze([]),
  flow: Object.freeze(['patch', 'deps']),
  test: Object.freeze(['patch', 'deps']),
  build: Object.freeze(['patch', 'deps', 'libgd']),
  audit: Object.freeze(['extract', 'patch', 'libgd', 'build']),
  prepare: Object.freeze(['audit']),
  package: Object.freeze([
    'extract',
    'deps',
    'patch',
    'libgd',
    'build',
    'audit',
    'prepare',
  ]),
  verify: Object.freeze(['package']),
});

export const PACKAGE_FAST_CHAIN = PIPELINE_PREREQUISITES.package;
export const DEVELOPMENT_PACKAGE_CHAIN = Object.freeze([
  'extract',
  'deps',
  'patch',
  'libgd',
  'build',
  'audit',
  'prepare',
]);
export const QUALITY_GATE_STEPS = Object.freeze(['flow', 'test']);

export const affectedPipelineSteps = changedStep => {
  if (!PIPELINE_STEPS.includes(changedStep)) {
    throw new TypeError(`Unknown pipeline step: ${changedStep}`);
  }
  const affected = new Set([changedStep]);
  let grew = true;
  while (grew) {
    grew = false;
    for (const step of PIPELINE_STEPS) {
      if (
        !affected.has(step) &&
        PIPELINE_INPUT_DEPENDENCIES[step].some(input => affected.has(input))
      ) {
        affected.add(step);
        grew = true;
      }
    }
  }
  return PIPELINE_STEPS.filter(step => affected.has(step));
};

export const planPipelineExecution = ({ target, statusByStep, automatic }) => {
  if (!PIPELINE_STEPS.includes(target)) {
    throw new TypeError(`Unknown pipeline target: ${target}`);
  }
  const steps = [];
  const hits = [];
  const visiting = new Set();
  const visit = step => {
    if (visiting.has(step)) throw new Error(`Pipeline dependency cycle at ${step}`);
    if (statusByStep[step]?.valid) {
      hits.push(step);
      return;
    }
    visiting.add(step);
    for (const prerequisite of PIPELINE_PREREQUISITES[step]) {
      if (!statusByStep[prerequisite]?.valid && !automatic) {
        throw new Error(
          `${step} requires valid ${prerequisite}: ${
            statusByStep[prerequisite]?.reason || 'missing receipt'
          }`
        );
      }
      visit(prerequisite);
    }
    visiting.delete(step);
    if (!steps.includes(step)) steps.push(step);
  };
  visit(target);
  return Object.freeze({ steps, hits });
};

export const createInFlightOperationDeduplicator = () => {
  const inFlightByKey = new Map();
  return (key, operation) => {
    if (typeof operation !== 'function') {
      throw new TypeError('In-flight operation must be a function');
    }
    const existing = inFlightByKey.get(key);
    if (existing) return existing;

    // Start on the next microtask so the shared promise is registered before
    // the operation can synchronously request the same key again.
    let shared;
    shared = Promise.resolve()
      .then(operation)
      .finally(() => {
        if (inFlightByKey.get(key) === shared) inFlightByKey.delete(key);
      });
    inFlightByKey.set(key, shared);
    return shared;
  };
};

export const commandGatePolicy = command => {
  if (command === 'dev-package') {
    return Object.freeze({
      required: DEVELOPMENT_PACKAGE_CHAIN,
      requiresQualityGates: false,
    });
  }
  if (command === 'package') {
    return Object.freeze({
      required: PACKAGE_FAST_CHAIN,
      requiresQualityGates: false,
    });
  }
  if (command === 'all' || command === 'release-check') {
    return Object.freeze({
      required: Object.freeze([...PACKAGE_FAST_CHAIN, ...QUALITY_GATE_STEPS]),
      requiresQualityGates: true,
    });
  }
  return Object.freeze({ required: Object.freeze([]), requiresQualityGates: false });
};

export const dependencyCacheKey = descriptor => digestRecord(descriptor);

export const dependencyNodeSearchPath = ({
  dependencyRoot,
  inheritedNodePath = '',
}) =>
  [path.join(dependencyRoot, 'node_modules'), inheritedNodePath]
    .filter(Boolean)
    .join(path.delimiter);

export const nodeOptionsWithHeapLimit = ({
  inheritedNodeOptions = '',
  maxOldSpaceSizeMb,
}) => {
  if (!Number.isSafeInteger(maxOldSpaceSizeMb) || maxOldSpaceSizeMb < 4096) {
    throw new TypeError('Node heap limit must be an integer of at least 4096 MB');
  }
  const tokens = inheritedNodeOptions.trim().split(/\s+/).filter(Boolean);
  const retained = [];
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index];
    if (/^--max[-_]old[-_]space[-_]size=/.test(token)) continue;
    if (/^--max[-_]old[-_]space[-_]size$/.test(token)) {
      index += 1;
      continue;
    }
    retained.push(token);
  }
  retained.push(`--max-old-space-size=${maxOldSpaceSizeMb}`);
  return retained.join(' ');
};

export const resolveNpmCliInvocation = nodeExecutable => {
  const command = path.resolve(nodeExecutable);
  const nodeDirectory = path.dirname(command);
  const portableCliPath = path.join(
    nodeDirectory,
    'node_modules',
    'npm',
    'bin',
    'npm-cli.js'
  );
  const unixCliPath = path.resolve(
    nodeDirectory,
    '..',
    'lib',
    'node_modules',
    'npm',
    'bin',
    'npm-cli.js'
  );
  return Object.freeze({
    command,
    // Official Windows Node ZIP/install layouts keep npm next to node.exe,
    // while Unix installations normally place it under ../lib. Keep npm
    // pinned to this Node installation instead of falling back to PATH.
    cliPath: existsSync(portableCliPath) ? portableCliPath : unixCliPath,
  });
};

export const libGdCacheIdentity = value =>
  Object.freeze({
    schemaVersion: value.schemaVersion,
    kind: value.kind,
    pin: value.pin,
    revision: value.revision,
    urlIdentity: value.urlIdentity,
    userDecision: value.userDecision,
    files: value.files,
    pairing: value.pairing,
  });

export const libGdCacheKey = value => digestRecord(libGdCacheIdentity(value));

export const assertArtifactIdentity = ({ expected, actual, label }) => {
  if (stableJson(expected) !== stableJson(actual)) {
    throw new Error(`${label} identity mismatch`);
  }
  return actual;
};

export const runReceiptTransaction = async ({
  execute,
  createSuccessReceipt,
  commitReceipt,
  signal,
}) => {
  if (signal?.aborted) throw new Error('Pipeline interrupted before step start');
  const result = await execute();
  if (signal?.aborted) throw new Error('Pipeline interrupted before receipt commit');
  const receipt = await createSuccessReceipt(result);
  if (signal?.aborted) throw new Error('Pipeline interrupted before receipt commit');
  await commitReceipt(receipt);
  return result;
};

export const createStatusReport = ({
  profile,
  sourceArchive,
  archiveSha256,
  workRoot,
  steps,
}) =>
  Object.freeze({ profile, sourceArchive, archiveSha256, workRoot, steps });

const booleanOptions = new Set([
  '--json',
  '--force-deps-refresh',
  '--keep-worktree-on-failure',
  '--adopt-successful-build',
]);
const valueOptions = new Set([
  '--zip',
  '--profile',
  '--from',
  '--to',
  '--libgd-seed',
  '--libgd-pin',
  '--libgd-revision',
  '--libgd-url-identity',
  '--libgd-source-kind',
  '--node-heap-mb',
]);

export const parsePipelineArguments = argv => {
  if (argv.length === 0 || !PIPELINE_COMMANDS.includes(argv[0])) {
    throw new TypeError(
      `First argument must be one of: ${PIPELINE_COMMANDS.join(', ')}`
    );
  }
  const command = argv[0];
  const options = new Map();
  for (let index = 1; index < argv.length; index += 1) {
    const name = argv[index];
    if (options.has(name)) throw new TypeError(`Duplicate option: ${name}`);
    if (booleanOptions.has(name)) {
      options.set(name, true);
      continue;
    }
    if (!valueOptions.has(name)) throw new TypeError(`Unknown option: ${name}`);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) {
      throw new TypeError(`${name} requires a value`);
    }
    options.set(name, value);
    index += 1;
  }
  if (!options.has('--zip')) throw new TypeError('--zip is required');
  if (!path.isAbsolute(options.get('--zip'))) {
    throw new TypeError('--zip must be an absolute path');
  }
  const profile = options.get('--profile') || 'default';
  if (profile !== 'default') {
    throw new TypeError('--profile is fixed to default so the build cache is reused');
  }
  options.set('--profile', profile);
  return Object.freeze({ command, options });
};

export const selectPipelineSteps = ({ command, from, to }) => {
  if (!['all', 'release-check'].includes(command) && (from || to)) {
    throw new TypeError('--from/--to are only valid with all or release-check');
  }
  if (!['all', 'release-check'].includes(command)) {
    return PIPELINE_STEPS.includes(command) ? [command] : [];
  }
  const finalStep = command === 'release-check' ? 'prepare' : 'verify';
  const start = from ? PIPELINE_STEPS.indexOf(from) : 0;
  const end = to ? PIPELINE_STEPS.indexOf(to) : PIPELINE_STEPS.indexOf(finalStep);
  if (start < 0 || end < 0 || start > end) {
    throw new TypeError('Invalid --from/--to pipeline range');
  }
  if (command === 'release-check' && end > PIPELINE_STEPS.indexOf('prepare')) {
    throw new TypeError('release-check cannot run package or verify');
  }
  return PIPELINE_STEPS.slice(start, end + 1);
};

export const sha256Bytes = value =>
  createHash('sha256').update(value).digest('hex');

export const sha256File = async filePath => {
  const digest = createHash('sha256');
  const stream = createReadStream(filePath);
  stream.on('data', chunk => digest.update(chunk));
  await once(stream, 'end');
  return digest.digest('hex');
};

export const stableJson = value => {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map(key => `${JSON.stringify(key)}:${stableJson(value[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
};

export const digestRecord = value => sha256Bytes(stableJson(value));

const normalizeRelative = value => value.split(path.sep).join('/');

export const computeTreeDigest = async ({
  root,
  excludeNames = new Set(),
  excludeRelativePaths = new Set(),
  rejectSymlinks = false,
}) => {
  const canonicalRoot = path.resolve(root);
  const records = [];
  const visit = async (directory, relativeDirectory = '') => {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((left, right) => left.name.localeCompare(right.name, 'en'));
    for (const entry of entries) {
      if (excludeNames.has(entry.name)) continue;
      const relative = normalizeRelative(path.join(relativeDirectory, entry.name));
      if (excludeRelativePaths.has(relative)) continue;
      const absolute = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        if (rejectSymlinks) throw new Error(`Symlink is forbidden: ${relative}`);
        records.push({ path: relative, type: 'symlink' });
      } else if (entry.isDirectory()) {
        records.push({ path: `${relative}/`, type: 'directory' });
        await visit(absolute, relative);
      } else if (entry.isFile()) {
        const metadata = await stat(absolute);
        records.push({
          path: relative,
          type: 'file',
          size: metadata.size,
          sha256: await sha256File(absolute),
        });
      } else {
        throw new Error(`Unsupported filesystem entry: ${relative}`);
      }
    }
  };
  await visit(canonicalRoot);
  return Object.freeze({ sha256: digestRecord(records), records });
};

// Keep stable build/Flow worktrees and only touch files whose bytes changed.
// Preserving unchanged mtimes is important for Webpack and Flow incremental caches.
export const synchronizeDirectoryByContent = async ({
  source,
  destination,
  excludeRelativePaths = new Set(),
}) => {
  const sourceRoot = path.resolve(source);
  const destinationRoot = path.resolve(destination);
  if (sourceRoot === destinationRoot) {
    throw new TypeError('Incremental sync source and destination must differ');
  }
  await mkdir(destinationRoot, { recursive: true });

  const sourceTree = await computeTreeDigest({
    root: sourceRoot,
    excludeRelativePaths,
    rejectSymlinks: true,
  });
  const destinationTree = await computeTreeDigest({
    root: destinationRoot,
    excludeRelativePaths,
    rejectSymlinks: true,
  });
  const sourceRecords = new Map(sourceTree.records.map(record => [record.path, record]));
  const destinationRecords = new Map(
    destinationTree.records.map(record => [record.path, record])
  );

  const stale = destinationTree.records
    .filter(record => !sourceRecords.has(record.path))
    .sort((left, right) => right.path.length - left.path.length);
  for (const record of stale) {
    const relative = record.path.endsWith('/') ? record.path.slice(0, -1) : record.path;
    if (!relative) continue;
    const target = ensureWithin(
      destinationRoot,
      path.join(destinationRoot, ...relative.split('/')),
      'incremental sync target'
    );
    await rm(target, { recursive: true, force: true });
  }

  let copied = 0;
  let unchanged = 0;
  for (const record of sourceTree.records) {
    const relative = record.path.endsWith('/') ? record.path.slice(0, -1) : record.path;
    const target = ensureWithin(
      destinationRoot,
      path.join(destinationRoot, ...relative.split('/')),
      'incremental sync target'
    );
    if (record.type === 'directory') {
      await mkdir(target, { recursive: true });
      continue;
    }
    const existing = destinationRecords.get(record.path);
    if (
      existing?.type === 'file' &&
      existing.size === record.size &&
      existing.sha256 === record.sha256
    ) {
      unchanged += 1;
      continue;
    }
    await mkdir(path.dirname(target), { recursive: true });
    await copyFile(path.join(sourceRoot, ...record.path.split('/')), target);
    copied += 1;
  }
  return Object.freeze({
    copied,
    unchanged,
    removed: stale.length,
    sourceTreeSha256: sourceTree.sha256,
  });
};

export const ensureWithin = (parent, candidate, label = 'path') => {
  const parentPath = path.resolve(parent);
  const candidatePath = path.resolve(candidate);
  const relative = path.relative(parentPath, candidatePath);
  if (
    relative.startsWith('..') ||
    path.isAbsolute(relative) ||
    relative === ''
  ) {
    throw new Error(`${label} must be a child of ${parentPath}: ${candidatePath}`);
  }
  return candidatePath;
};

export const writeJsonAtomically = async (filePath, value) => {
  await mkdir(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.${process.pid}.${randomUUID()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: 'utf8',
    flag: 'wx',
  });
  await rename(temporary, filePath);
};

const defaultIsProcessAlive = pid => {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error && error.code === 'ESRCH') return false;
    // EPERM means that the process exists but cannot be signalled. Fail closed
    // for every other platform-specific error as well.
    return true;
  }
};

export const acquireProjectLock = async ({
  lockPath,
  profile,
  command,
  isProcessAlive = defaultIsProcessAlive,
}) => {
  await mkdir(path.dirname(lockPath), { recursive: true });
  let handle;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      handle = await open(lockPath, 'wx');
      break;
    } catch (error) {
      if (!error || error.code !== 'EEXIST') throw error;
      let ownerText = 'unknown owner';
      let owner = null;
      try {
        ownerText = (await readFile(lockPath, 'utf8')).trim();
        owner = JSON.parse(ownerText);
      } catch {}
      if (!owner || isProcessAlive(owner.pid)) {
        throw new Error(`WebIDE pipeline profile is locked: ${ownerText}`);
      }
      if (attempt > 0) {
        throw new Error(`Unable to replace stale WebIDE pipeline lock: ${ownerText}`);
      }
      await rm(lockPath, { force: true });
    }
  }
  if (!handle) throw new Error('Unable to acquire WebIDE pipeline profile lock');
  const token = randomUUID();
  await handle.writeFile(
    `${JSON.stringify({
      pid: process.pid,
      token,
      profile,
      command,
      startedAt: new Date().toISOString(),
    })}\n`
  );
  await handle.close();
  let released = false;
  return async () => {
    if (released) return;
    released = true;
    try {
      const owner = JSON.parse(await readFile(lockPath, 'utf8'));
      if (owner.token === token) await rm(lockPath, { force: true });
    } catch (error) {
      if (!error || error.code !== 'ENOENT') throw error;
    }
  };
};

export const readReceipt = async receiptPath => {
  try {
    return JSON.parse(await readFile(receiptPath, 'utf8'));
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
    return Object.freeze({ malformed: true, error: String(error) });
  }
};

export const receiptOutputTreeDigest = async receiptOrPromise => {
  const receipt = await receiptOrPromise;
  if (
    !receipt ||
    receipt.malformed ||
    receipt.schemaVersion !== 1 ||
    !/^[0-9a-f]{64}$/.test(receipt.outputTreeDigest || '')
  ) {
    return null;
  }
  return receipt.outputTreeDigest;
};

export const resolvePipelineReceiptInputs = async ({ step, receiptFor }) => {
  const dependencies = PIPELINE_INPUT_DEPENDENCIES[step];
  if (!dependencies) throw new TypeError(`Unknown pipeline step: ${step}`);
  if (typeof receiptFor !== 'function') {
    throw new TypeError('receiptFor must be a function');
  }
  return Object.freeze(
    Object.fromEntries(
      await Promise.all(
        dependencies.map(async dependency => [
          dependency,
          await receiptOutputTreeDigest(receiptFor(dependency)),
        ])
      )
    )
  );
};

const explainReceiptMetadata = ({ receipt, step, inputDigest }) => {
  if (!receipt) return { valid: false, reason: 'missing receipt' };
  if (receipt.malformed) return { valid: false, reason: 'malformed receipt' };
  if (receipt.schemaVersion !== 1) {
    return { valid: false, reason: 'unsupported receipt schema' };
  }
  if (receipt.step !== step) return { valid: false, reason: 'step mismatch' };
  if (receipt.inputDigest !== inputDigest) {
    return { valid: false, reason: 'input digest changed' };
  }
  return null;
};

export const explainReceipt = ({ receipt, step, inputDigest, outputDigest }) => {
  const metadataFailure = explainReceiptMetadata({ receipt, step, inputDigest });
  if (metadataFailure) return metadataFailure;
  if (outputDigest === null) {
    return { valid: false, reason: 'output missing or invalid' };
  }
  if (receipt.outputTreeDigest !== outputDigest) {
    return { valid: false, reason: 'output tree digest changed' };
  }
  return { valid: true, reason: 'receipt hit' };
};

export const evaluateReceiptStatus = async ({
  receipt,
  step,
  inputDigest,
  readOutputDigest,
}) => {
  const metadataFailure = explainReceiptMetadata({ receipt, step, inputDigest });
  if (metadataFailure) {
    return { ...metadataFailure, outputTreeDigest: null };
  }
  if (typeof readOutputDigest !== 'function') {
    throw new TypeError('readOutputDigest must be a function');
  }
  const outputTreeDigest = await readOutputDigest();
  return {
    ...explainReceipt({
      receipt,
      step,
      inputDigest,
      outputDigest: outputTreeDigest,
    }),
    outputTreeDigest,
  };
};

export const createReceipt = ({
  step,
  inputDigest,
  input,
  toolVersions,
  outputTreeDigest,
}) =>
  Object.freeze({
    schemaVersion: 1,
    step,
    inputDigest,
    input,
    toolVersions,
    outputTreeDigest,
    completedAt: new Date().toISOString(),
  });

export const runProcess = async ({
  command,
  args,
  cwd,
  env,
  signal,
  logPath,
  spawnImplementation = spawn,
  stdout = process.stdout,
  stderr = process.stderr,
}) => {
  await mkdir(path.dirname(logPath), { recursive: true });
  const logHandle = await open(logPath, 'w');
  let pendingLogWrite = Promise.resolve();
  const writeLog = chunk => {
    pendingLogWrite = pendingLogWrite.then(() => logHandle.write(chunk));
  };
  let processFailure = null;
  try {
    const child = spawnImplementation(command, args, {
      cwd,
      env: { ...process.env, ...env },
      signal,
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    child.stdout.on('data', chunk => {
      stdout.write(chunk);
      writeLog(chunk);
    });
    child.stderr.on('data', chunk => {
      stderr.write(chunk);
      writeLog(chunk);
    });

    // `exit` can precede the final stdout/stderr `data` events. `close` is the
    // ChildProcess boundary that guarantees its stdio streams have closed, so
    // only then is it safe to drain the queued log writes and close the file.
    let childFailure = null;
    child.once('error', error => {
      childFailure ??= error;
    });
    const [code, terminationSignal] = await new Promise(resolve => {
      child.once('close', (...result) => resolve(result));
    });
    if (childFailure) throw childFailure;
    if (code !== 0) {
      throw new Error(
        `${command} exited with ${code ?? `signal ${terminationSignal || 'unknown'}`}`
      );
    }
  } catch (error) {
    processFailure = error;
  }

  let logFailure = null;
  try {
    await pendingLogWrite;
  } catch (error) {
    logFailure = error;
  }
  try {
    await logHandle.close();
  } catch (error) {
    logFailure ??= error;
  }
  if (processFailure) throw processFailure;
  if (logFailure) throw logFailure;
};

const renameWithTransientRetry = async (source, destination) => {
  const retryable = new Set(['EACCES', 'EPERM', 'EBUSY']);
  for (let attempt = 0; ; attempt += 1) {
    try {
      await rename(source, destination);
      return;
    } catch (error) {
      if (!retryable.has(error?.code) || attempt >= 119) throw error;
      // DrvFS/Windows security scanners can retain a directory handle briefly
      // after thousands of extracted files are closed.
      await new Promise(resolve => setTimeout(resolve, 250));
    }
  }
};

export const replaceDirectoryAtomically = async ({ staging, target }) => {
  const backup = `${target}.backup-${randomUUID()}`;
  let hadTarget = false;
  try {
    try {
      await renameWithTransientRetry(target, backup);
      hadTarget = true;
    } catch (error) {
      if (!error || error.code !== 'ENOENT') throw error;
    }
    await renameWithTransientRetry(staging, target);
    if (hadTarget) await rm(backup, { recursive: true, force: true });
  } catch (error) {
    // Never touch the old target unless it was first moved successfully. If
    // promoting staging failed, target can only be a partial/new directory.
    if (hadTarget) {
      await rm(target, { recursive: true, force: true });
      await renameWithTransientRetry(backup, target);
    }
    throw error;
  }
};

const findEndOfCentralDirectory = bytes => {
  const minimum = Math.max(0, bytes.length - 0xffff - 22);
  for (let offset = bytes.length - 22; offset >= minimum; offset -= 1) {
    if (bytes.readUInt32LE(offset) === 0x06054b50) return offset;
  }
  throw new Error('ZIP end-of-central-directory record is missing');
};

const safeZipPath = name => {
  const normalized = name.replaceAll('\\', '/');
  const withoutTrailingSlash = normalized.endsWith('/')
    ? normalized.slice(0, -1)
    : normalized;
  const parts = withoutTrailingSlash.split('/');
  if (
    normalized.startsWith('/') ||
    /^[A-Za-z]:/.test(normalized) ||
    withoutTrailingSlash.length === 0 ||
    parts.some(part => part === '..' || part === '.' || part === '')
  ) {
    throw new Error(`Unsafe ZIP entry path: ${name}`);
  }
  return normalized;
};

export const inspectZip = async ({ archivePath, maximumBytes = 12 * 1024 ** 3 }) => {
  const bytes = await readFile(archivePath);
  const eocd = findEndOfCentralDirectory(bytes);
  const entryCount = bytes.readUInt16LE(eocd + 10);
  const centralSize = bytes.readUInt32LE(eocd + 12);
  const centralOffset = bytes.readUInt32LE(eocd + 16);
  if (entryCount === 0xffff || centralSize === 0xffffffff || centralOffset === 0xffffffff) {
    throw new Error('ZIP64 source archives are not accepted');
  }
  const entries = [];
  const entryNames = new Set();
  let offset = centralOffset;
  let totalUncompressed = 0;
  for (let index = 0; index < entryCount; index += 1) {
    if (bytes.readUInt32LE(offset) !== 0x02014b50) {
      throw new Error('ZIP central-directory entry is malformed');
    }
    const flags = bytes.readUInt16LE(offset + 8);
    const compression = bytes.readUInt16LE(offset + 10);
    const compressedSize = bytes.readUInt32LE(offset + 20);
    const uncompressedSize = bytes.readUInt32LE(offset + 24);
    const nameLength = bytes.readUInt16LE(offset + 28);
    const extraLength = bytes.readUInt16LE(offset + 30);
    const commentLength = bytes.readUInt16LE(offset + 32);
    const externalAttributes = bytes.readUInt32LE(offset + 38);
    const localOffset = bytes.readUInt32LE(offset + 42);
    const name = safeZipPath(
      bytes.subarray(offset + 46, offset + 46 + nameLength).toString('utf8')
    );
    if (entryNames.has(name)) throw new Error(`Duplicate ZIP entry: ${name}`);
    entryNames.add(name);
    if ((flags & 1) !== 0) throw new Error(`Encrypted ZIP entry is forbidden: ${name}`);
    if (![0, 8].includes(compression)) {
      throw new Error(`Unsupported ZIP compression ${compression}: ${name}`);
    }
    const unixMode = externalAttributes >>> 16;
    if ((unixMode & 0o170000) === 0o120000) {
      throw new Error(`ZIP symlink is forbidden: ${name}`);
    }
    totalUncompressed += uncompressedSize;
    if (!Number.isSafeInteger(totalUncompressed) || totalUncompressed > maximumBytes) {
      throw new Error('ZIP uncompressed size exceeds the safety limit');
    }
    const crc32 = bytes.readUInt32LE(offset + 16);
    entries.push({
      name,
      compression,
      compressedSize,
      uncompressedSize,
      localOffset,
      crc32,
    });
    offset += 46 + nameLength + extraLength + commentLength;
  }
  if (offset !== centralOffset + centralSize) {
    throw new Error('ZIP central-directory size does not match its records');
  }
  return Object.freeze({ bytes, entries, totalUncompressed });
};

const crcTable = (() => {
  const table = new Uint32Array(256);
  for (let index = 0; index < 256; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) {
      value = (value & 1) !== 0 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
    table[index] = value >>> 0;
  }
  return table;
})();

export const crc32Bytes = bytes => {
  let value = 0xffffffff;
  for (const byte of bytes) value = crcTable[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
};

export const assertAvailableDiskSpace = async ({
  destination,
  requiredBytes,
  marginBytes = Math.max(256 * 1024 * 1024, Math.ceil(requiredBytes * 0.1)),
  statfsImplementation = statfs,
}) => {
  const filesystem = await statfsImplementation(destination);
  const availableBytes = Number(filesystem.bavail) * Number(filesystem.bsize);
  const minimumBytes = requiredBytes + marginBytes;
  if (!Number.isSafeInteger(availableBytes) || availableBytes < minimumBytes) {
    throw new Error(
      `Insufficient disk space: need ${minimumBytes} bytes, have ${availableBytes}`
    );
  }
  return Object.freeze({ availableBytes, minimumBytes });
};

export const extractZipSafely = async ({
  archivePath,
  destination,
  expectedRoot,
  statfsImplementation = statfs,
}) => {
  const inspected = await inspectZip({ archivePath });
  const roots = new Set(inspected.entries.map(entry => entry.name.split('/')[0]));
  if (roots.size !== 1 || !roots.has(expectedRoot)) {
    throw new Error(`ZIP root must be exactly ${expectedRoot}`);
  }
  await mkdir(destination, { recursive: true });
  await assertAvailableDiskSpace({
    destination,
    requiredBytes: inspected.totalUncompressed,
    statfsImplementation,
  });
  for (const entry of inspected.entries) {
    const relative = entry.name.split('/').slice(1).join('/');
    if (!relative) continue;
    const output = path.resolve(destination, ...relative.split('/'));
    const allowed = path.relative(destination, output);
    if (allowed.startsWith('..') || path.isAbsolute(allowed)) {
      throw new Error(`ZIP entry escapes extraction root: ${entry.name}`);
    }
    if (entry.name.endsWith('/')) {
      await mkdir(output, { recursive: true });
      continue;
    }
    const local = entry.localOffset;
    if (inspected.bytes.readUInt32LE(local) !== 0x04034b50) {
      throw new Error(`ZIP local header is malformed: ${entry.name}`);
    }
    const localNameLength = inspected.bytes.readUInt16LE(local + 26);
    const localExtraLength = inspected.bytes.readUInt16LE(local + 28);
    const localName = safeZipPath(
      inspected.bytes
        .subarray(local + 30, local + 30 + localNameLength)
        .toString('utf8')
    );
    if (localName !== entry.name) {
      throw new Error(`ZIP local/central name mismatch: ${entry.name}`);
    }
    const dataOffset = local + 30 + localNameLength + localExtraLength;
    if (
      dataOffset < 0 ||
      dataOffset + entry.compressedSize > inspected.bytes.length
    ) {
      throw new Error(`ZIP entry data is out of bounds: ${entry.name}`);
    }
    const compressed = inspected.bytes.subarray(
      dataOffset,
      dataOffset + entry.compressedSize
    );
    const contents =
      entry.compression === 0 ? compressed : inflateRawSync(compressed);
    if (contents.length !== entry.uncompressedSize) {
      throw new Error(`ZIP entry size mismatch: ${entry.name}`);
    }
    if (crc32Bytes(contents) !== entry.crc32) {
      throw new Error(`ZIP entry CRC mismatch: ${entry.name}`);
    }
    await mkdir(path.dirname(output), { recursive: true });
    await writeFile(output, contents, { flag: 'wx' });
  }
  return inspected.totalUncompressed;
};

export const copyTreeWithoutDependencies = async ({ source, destination }) => {
  await cp(source, destination, {
    recursive: true,
    force: false,
    filter: candidate => path.basename(candidate) !== 'node_modules',
  });
};

export const validateDependencyCache = async (
  cacheRoot,
  { scope = 'app' } = {}
) => {
  const executableSuffix = process.platform === 'win32' ? '.cmd' : '';
  const required =
    scope === 'gdjs'
      ? [
          'node_modules/.package-lock.json',
          `node_modules/.bin/esbuild${executableSuffix}`,
          'node_modules/@pixi/core/package.json',
        ]
      : [
          'node_modules/.package-lock.json',
          `node_modules/.bin/react-app-rewired${executableSuffix}`,
          `node_modules/.bin/flow${executableSuffix}`,
        ];
  const records = [];
  try {
    for (const relative of required) {
      const filePath = path.join(cacheRoot, ...relative.split('/'));
      const metadata = await stat(filePath);
      if (!metadata.isFile() || metadata.size === 0) return null;
      records.push({ relative, size: metadata.size, sha256: await sha256File(filePath) });
    }
  } catch {
    return null;
  }
  return digestRecord(records);
};

export const validateLibGdPair = async directory => {
  const result = {};
  for (const fileName of ['libGD.js', 'libGD.wasm']) {
    const filePath = path.join(directory, fileName);
    const metadata = await stat(filePath);
    if (!metadata.isFile() || metadata.size === 0) {
      throw new Error(`${fileName} is missing or empty`);
    }
    result[fileName] = {
      sha256: await sha256File(filePath),
      size: metadata.size,
    };
  }
  const javascriptBytes = await readFile(path.join(directory, 'libGD.js'));
  const wasmBytes = await readFile(path.join(directory, 'libGD.wasm'));
  const pairing = verifyLibGdRuntimePairBytes({
    javascriptBytes,
    wasmBytes,
    label: 'WebIDE pipeline libGD cache',
  });
  return Object.freeze({ files: result, pairing });
};

export const canonicalPath = async value => realpath(path.resolve(value));

export const removeIfExists = async value => rm(value, { recursive: true, force: true });

export const cleanupPipelineTransientEntries = async ({
  root,
  prefixes = [],
  names = [],
}) => {
  const canonicalRoot = path.resolve(root);
  let entries;
  try {
    entries = await readdir(canonicalRoot, { withFileTypes: true });
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return Object.freeze({ removed: Object.freeze([]), failures: Object.freeze([]) });
    }
    throw error;
  }

  const exactNames = new Set(names);
  const removed = [];
  const failures = [];
  for (const entry of entries) {
    if (
      !exactNames.has(entry.name) &&
      !prefixes.some(prefix => entry.name.startsWith(prefix))
    ) {
      continue;
    }
    const target = ensureWithin(
      canonicalRoot,
      path.join(canonicalRoot, entry.name),
      'pipeline transient entry'
    );
    try {
      await rm(target, { recursive: true, force: true });
      removed.push(entry.name);
    } catch (error) {
      failures.push(
        Object.freeze({
          name: entry.name,
          message: error instanceof Error ? error.message : String(error),
        })
      );
    }
  }
  return Object.freeze({
    removed: Object.freeze(removed),
    failures: Object.freeze(failures),
  });
};

export const lstatOrNull = async value => {
  try {
    return await lstat(value);
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  }
};
