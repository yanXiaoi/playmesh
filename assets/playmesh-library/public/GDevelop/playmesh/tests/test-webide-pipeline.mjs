import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  assertAvailableDiskSpace,
  acquireProjectLock,
  affectedPipelineSteps,
  commandGatePolicy,
  cleanupPipelineTransientEntries,
  computeTreeDigest,
  crc32Bytes,
  createInFlightOperationDeduplicator,
  createReceipt,
  dependencyNodeSearchPath,
  digestRecord,
  evaluateReceiptStatus,
  explainReceipt,
  extractZipSafely,
  libGdCacheKey,
  nodeOptionsWithHeapLimit,
  parsePipelineArguments,
  planPipelineExecution,
  replaceDirectoryAtomically,
  resolvePipelineReceiptInputs,
  resolveNpmCliInvocation,
  runProcess,
  selectPipelineSteps,
  synchronizeDirectoryByContent,
  validateDependencyCache,
} from '../scripts/webide-pipeline-lib.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const temporaryRoots = [];
const pipelineSource = await readFile(
  path.resolve(testDirectory, '../scripts/webide-pipeline.mjs'),
  'utf8'
);
const temporaryRoot = async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'playmesh-webide-pipeline-'));
  temporaryRoots.push(root);
  return root;
};

test.after(async () => {
  for (const root of temporaryRoots) {
    await rm(root, { recursive: true, force: true });
  }
});

const controlledChildProcess = ({ code = 0, signal = null }) => {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  const spawnImplementation = () => {
    queueMicrotask(() => {
      child.stdout.write('stdout-before-exit\n');
      child.emit('exit', code, signal);
      setImmediate(() => {
        child.stdout.end('stdout-after-exit\n');
        child.stderr.end('stderr-after-exit\n');
        child.emit('close', code, signal);
      });
    });
    return child;
  };
  return { spawnImplementation };
};

test('process logs drain tail data after exit before the log handle closes', async () => {
  const root = await temporaryRoot();
  const logPath = path.join(root, 'process.log');
  const output = new PassThrough();
  const errorOutput = new PassThrough();
  const { spawnImplementation } = controlledChildProcess({});

  await runProcess({
    command: 'fixture-command',
    args: [],
    cwd: root,
    env: {},
    logPath,
    spawnImplementation,
    stdout: output,
    stderr: errorOutput,
  });

  assert.equal(
    await readFile(logPath, 'utf8'),
    'stdout-before-exit\nstdout-after-exit\nstderr-after-exit\n'
  );
});

test('process logs drain tail data before preserving a non-zero exit failure', async () => {
  const root = await temporaryRoot();
  const logPath = path.join(root, 'failed-process.log');
  const { spawnImplementation } = controlledChildProcess({ code: 23 });

  await assert.rejects(
    runProcess({
      command: 'fixture-command',
      args: [],
      cwd: root,
      env: {},
      logPath,
      spawnImplementation,
      stdout: new PassThrough(),
      stderr: new PassThrough(),
    }),
    /fixture-command exited with 23/
  );
  assert.equal(
    await readFile(logPath, 'utf8'),
    'stdout-before-exit\nstdout-after-exit\nstderr-after-exit\n'
  );
});

test('concurrent requests for one pipeline step share one in-flight operation', async () => {
  const shareInFlight = createInFlightOperationDeduplicator();
  let operationCount = 0;
  let releaseOperation;
  const operationGate = new Promise(resolve => {
    releaseOperation = resolve;
  });

  const first = shareInFlight('extract', async () => {
    operationCount += 1;
    await operationGate;
    return 'complete';
  });
  const second = shareInFlight('extract', async () => {
    operationCount += 1;
    return 'duplicate';
  });

  assert.equal(first, second);
  await Promise.resolve();
  assert.equal(operationCount, 1);
  releaseOperation();
  assert.deepEqual(await Promise.all([first, second]), [
    'complete',
    'complete',
  ]);
  assert.equal(
    await shareInFlight('extract', async () => {
      operationCount += 1;
      return 'rerun';
    }),
    'rerun'
  );
  assert.equal(operationCount, 2);
  assert.match(
    pipelineSource,
    /shareEnsureStep\(step, \(\) => ensureStepOnce\(step, automatic\)\)/
  );
  assert.match(
    pipelineSource,
    /Promise\.all\(\[ensureStep\("flow", true\), ensureStep\("test", true\)\]\)/
  );
  assert.match(
    pipelineSource,
    /for \(const step of DEVELOPMENT_PACKAGE_CHAIN\) \{\s*await ensureStep\(step, true\);\s*\}/
  );
});

test('in-flight step sharing preserves parallel keys and evicts failures', async () => {
  const shareInFlight = createInFlightOperationDeduplicator();
  const started = [];
  let releaseOperations;
  const operationGate = new Promise(resolve => {
    releaseOperations = resolve;
  });
  const flow = shareInFlight('flow', async () => {
    started.push('flow');
    await operationGate;
  });
  const contracts = shareInFlight('test', async () => {
    started.push('test');
    await operationGate;
  });
  await Promise.resolve();
  assert.deepEqual(started.sort(), ['flow', 'test']);
  releaseOperations();
  await Promise.all([flow, contracts]);

  let attempts = 0;
  const firstFailure = shareInFlight('extract', async () => {
    attempts += 1;
    throw new Error('injected failure');
  });
  const secondFailure = shareInFlight('extract', async () => {
    attempts += 1;
    throw new Error('duplicate failure');
  });
  assert.equal(firstFailure, secondFailure);
  await assert.rejects(
    Promise.all([firstFailure, secondFailure]),
    /injected failure/
  );
  assert.equal(attempts, 1);
  assert.equal(
    await shareInFlight('extract', async () => {
      attempts += 1;
      return 'recovered';
    }),
    'recovered'
  );
  assert.equal(attempts, 2);
});

test('transient cleanup removes staging and backups while preserving incremental caches', async () => {
  const root = await temporaryRoot();
  const removedNames = [
    '.staging-patch-fixture',
    '.prepared.staging-fixture',
    'source.backup-fixture',
    'release-check',
  ];
  const retainedNames = [
    'upstream',
    'source',
    'build-source',
    'prepared',
    'receipts',
    'logs',
  ];
  await Promise.all(
    [...removedNames, ...retainedNames].map(name =>
      mkdir(path.join(root, name), { recursive: true })
    )
  );

  const result = await cleanupPipelineTransientEntries({
    root,
    names: ['release-check'],
    prefixes: ['.staging-', '.prepared.staging-', 'source.backup-'],
  });

  assert.deepEqual(new Set(result.removed), new Set(removedNames));
  assert.deepEqual(result.failures, []);
  for (const name of removedNames) {
    await assert.rejects(stat(path.join(root, name)), { code: 'ENOENT' });
  }
  for (const name of retainedNames) {
    assert.ok((await stat(path.join(root, name))).isDirectory(), name);
  }
});

test('all package-producing commands target repository resources, not work', () => {
  assert.match(
    pipelineSource,
    /const publishFormalArtifacts = command !== "release-check"/
  );
  assert.match(
    pipelineSource,
    /const releaseDirectory = path\.join\(repositoryRoot, "resources", "GDevelop"\)/
  );
  assert.match(
    pipelineSource,
    /"--release-directory",\s*releaseDirectory/
  );
  assert.match(
    pipelineSource,
    /names: \["release-check", "release-output", "release-update\.json"\]/
  );
  assert.doesNotMatch(pipelineSource, /cleanupPipelineEntriesExcept/);
});

test('local contract gate includes every standalone AI contract test', () => {
  for (const testFile of [
    'test-ai-client.mjs',
    'test-ai-ui-boundaries.mjs',
    'test-ai-live-wrapper-callbacks.mjs',
    'test-ai-piskel-tools.mjs',
    'test-ai-official-local-editor-runners.mjs',
    'test-ai-return-status.mjs',
    'test-ai-runtime-debugger-tools.mjs',
  ]) {
    const entry = `["${testFile}", []]`;
    assert.equal(
      pipelineSource.split(entry).length - 1,
      1,
      `${testFile} must be wired into localContractTests exactly once`
    );
  }
});

test('local contract gate includes the embedded external-editor window contract', () => {
  const entry = '["test-embedded-external-editor-window.mjs", []]';
  assert.equal(
    pipelineSource.split(entry).length - 1,
    1,
    'the embedded external-editor window contract must run exactly once'
  );
});

test('local contract gate includes the history request race contract', () => {
  const entry = '["test-history-request-coordinator.mjs", []]';
  assert.equal(
    pipelineSource.split(entry).length - 1,
    1,
    'the history request race contract must run exactly once'
  );
});

test('local contract gate includes every external-editor localization contract', () => {
  for (const testFile of [
    'test-piskel-localization.mjs',
    'test-external-editor-i18n-derivatives.mjs',
  ]) {
    const entry = `["${testFile}", []]`;
    assert.equal(
      pipelineSource.split(entry).length - 1,
      1,
      `${testFile} must be wired into localContractTests exactly once`
    );
  }
});

test('source contract gate includes the compiled iframe lifecycle contract', () => {
  const entry =
    '["test-external-editor-iframe-lifecycle.mjs", ["--source", "{source}"]]';
  assert.equal(
    pipelineSource.split(entry).length - 1,
    1,
    'the compiled external-editor iframe lifecycle contract must run exactly once'
  );
});

test('source contract gate includes the Yarn cold-start contract', () => {
  const entry =
    '["test-yarn-external-editor-cold-start.mjs", ["--source", "{source}"]]';
  assert.equal(
    pipelineSource.split(entry).length - 1,
    1,
    'the Yarn syntax and cold-start readiness contract must run exactly once'
  );
});

test('CLI requires a subcommand and absolute official ZIP', () => {
  assert.throws(() => parsePipelineArguments(['status', '--zip', 'relative.zip']));
  const archive = path.resolve('official.zip');
  const parsed = parsePipelineArguments([
    'status',
    '--zip',
    archive,
    '--json',
    '--adopt-successful-build',
  ]);
  assert.equal(parsed.command, 'status');
  assert.equal(parsed.options.get('--zip'), archive);
  assert.equal(parsed.options.get('--profile'), 'default');
  assert.equal(parsed.options.get('--json'), true);
  assert.equal(parsed.options.get('--adopt-successful-build'), true);
  assert.throws(
    () =>
      parsePipelineArguments([
        'status',
        '--zip',
        archive,
        '--profile',
        'upgrade-269',
      ]),
    /fixed to default/
  );
});

test('all range is explicit while a single command cannot hide behind from/to', () => {
  assert.deepEqual(
    selectPipelineSteps({ command: 'all', from: 'patch', to: 'build' }),
    ['patch', 'libgd', 'flow', 'test', 'build']
  );
  assert.throws(() =>
    selectPipelineSteps({ command: 'package', from: 'build', to: 'package' })
  );
  assert.throws(() =>
    selectPipelineSteps({
      command: 'release-check',
      from: 'prepare',
      to: 'package',
    })
  );
});

test('all package range retains complete quality gates while fast package does not', () => {
  assert.deepEqual(
    selectPipelineSteps({ command: 'all', from: 'package', to: 'verify' }),
    ['package', 'verify']
  );
  assert.equal(commandGatePolicy('all').requiresQualityGates, true);
  assert.deepEqual(commandGatePolicy('all').required.slice(-2), ['flow', 'test']);
  assert.equal(commandGatePolicy('package').requiresQualityGates, false);
  const development = commandGatePolicy('dev-package');
  assert.equal(development.requiresQualityGates, false);
  assert.deepEqual(development.required, [
    'extract',
    'deps',
    'patch',
    'libgd',
    'build',
    'audit',
    'prepare',
  ]);
  assert.equal(development.required.includes('flow'), false);
  assert.equal(development.required.includes('test'), false);
  assert.equal(development.required.includes('audit'), true);
  assert.equal(development.required.includes('prepare'), true);
});

test('development package is a first-class CLI command', () => {
  const archive = path.resolve('official.zip');
  const parsed = parsePipelineArguments(['dev-package', '--zip', archive]);
  assert.equal(parsed.command, 'dev-package');
  assert.deepEqual(
    selectPipelineSteps({ command: 'dev-package' }),
    []
  );
});

test('npm invocation is pinned beside the current Node instead of PATH', () => {
  const node = path.resolve('/opt/playmesh/node-v20/bin/node');
  const invocation = resolveNpmCliInvocation(node);
  assert.equal(invocation.command, node);
  assert.equal(
    invocation.cliPath,
    path.resolve('/opt/playmesh/node-v20/lib/node_modules/npm/bin/npm-cli.js')
  );
});

test('npm invocation supports the portable Windows-style Node layout', async () => {
  const root = await temporaryRoot();
  const node = path.join(root, 'node.exe');
  const npmCli = path.join(root, 'node_modules', 'npm', 'bin', 'npm-cli.js');
  await mkdir(path.dirname(npmCli), { recursive: true });
  await writeFile(node, 'fixture');
  await writeFile(npmCli, 'fixture');
  const invocation = resolveNpmCliInvocation(node);
  assert.equal(invocation.command, path.resolve(node));
  assert.equal(invocation.cliPath, npmCli);
});

test('official GDJS helpers reuse the exact app dependency cache through NODE_PATH', () => {
  const dependencyRoot = path.resolve('/cache/dependencies/exact-key');
  assert.equal(
    dependencyNodeSearchPath({
      dependencyRoot,
      inheritedNodePath: path.resolve('/existing/modules'),
    }),
    [
      path.join(dependencyRoot, 'node_modules'),
      path.resolve('/existing/modules'),
    ].join(path.delimiter)
  );
});

test('Windows Flow uses per-package links and a verified local libGD test module', () => {
  assert.match(
    pipelineSource,
    /case "flow":[\s\S]*?isolated: process\.platform === "win32"/
  );
  assert.match(
    pipelineSource,
    /case "flow":[\s\S]*?materializeLibGdTestModule\([\s\S]*?libGdConfig\.cachePath/
  );
  assert.match(
    pipelineSource,
    /materializeLibGdTestModule[\s\S]*?libGD\.js-for-tests-only[\s\S]*?index\.js[\s\S]*?libGD\.wasm/
  );
});

test('GDJS build writes the runtime into the cached GDJS tree', () => {
  assert.match(
    pipelineSource,
    /const generatedGdjsRoot = path\.join\([\s\S]*?["']resources["'],[\s\S]*?["']GDJS["']/
  );
  assert.match(
    pipelineSource,
    /path\.join\(\s*generatedGdjsRoot,\s*["']Runtime["'],\s*["']libs["'],\s*["']jshashtable\.js["']/
  );
  assert.match(pipelineSource, /["']--gdjs["'],\s*generatedGdjsRoot/);
});

test('production build heap limit replaces inherited aliases deterministically', () => {
  assert.equal(
    nodeOptionsWithHeapLimit({
      inheritedNodeOptions:
        '--trace-warnings --max_old_space_size 4096 --no-deprecation',
      maxOldSpaceSizeMb: 8192,
    }),
    '--trace-warnings --no-deprecation --max-old-space-size=8192'
  );
  assert.equal(
    nodeOptionsWithHeapLimit({
      inheritedNodeOptions: '--max-old-space-size=6144',
      maxOldSpaceSizeMb: 12288,
    }),
    '--max-old-space-size=12288'
  );
  assert.throws(
    () => nodeOptionsWithHeapLimit({ maxOldSpaceSizeMb: 2048 }),
    /at least 4096 MB/
  );
});

test('dependency caches validate app and GDJS runtime requirements independently', async () => {
  const root = await temporaryRoot();
  const suffix = process.platform === 'win32' ? '.cmd' : '';
  const required = [
    'app/node_modules/.package-lock.json',
    `app/node_modules/.bin/react-app-rewired${suffix}`,
    `app/node_modules/.bin/flow${suffix}`,
    'gdjs/node_modules/.package-lock.json',
    `gdjs/node_modules/.bin/esbuild${suffix}`,
    'gdjs/node_modules/@pixi/core/package.json',
  ];
  for (const relative of required) {
    const target = path.join(root, ...relative.split('/'));
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, 'fixture');
  }
  assert.ok(await validateDependencyCache(path.join(root, 'app')));
  assert.ok(
    await validateDependencyCache(path.join(root, 'gdjs'), { scope: 'gdjs' })
  );
  await rm(path.join(root, 'gdjs', 'node_modules', '@pixi'), {
    recursive: true,
    force: true,
  });
  assert.equal(
    await validateDependencyCache(path.join(root, 'gdjs'), { scope: 'gdjs' }),
    null
  );
});

test('receipt reports exact invalidation reason', () => {
  const receipt = createReceipt({
    step: 'patch',
    inputDigest: 'input-a',
    input: { source: 'a' },
    toolVersions: { node: 'v1' },
    outputTreeDigest: 'tree-a',
  });
  assert.deepEqual(
    explainReceipt({
      receipt,
      step: 'patch',
      inputDigest: 'input-a',
      outputDigest: 'tree-a',
    }),
    { valid: true, reason: 'receipt hit' }
  );
  assert.equal(
    explainReceipt({
      receipt,
      step: 'patch',
      inputDigest: 'input-b',
      outputDigest: 'tree-a',
    }).reason,
    'input digest changed'
  );
  assert.equal(
    explainReceipt({
      receipt,
      step: 'patch',
      inputDigest: 'input-a',
      outputDigest: 'tree-b',
    }).reason,
    'output tree digest changed'
  );
});

test('receipt status hashes output only after receipt metadata and input match', async () => {
  const receipt = createReceipt({
    step: 'prepare',
    inputDigest: 'input-a',
    input: { source: 'a' },
    toolVersions: { node: 'v1' },
    outputTreeDigest: 'tree-a',
  });
  let outputReads = 0;
  const readOutputDigest = async () => {
    outputReads += 1;
    return 'tree-a';
  };

  for (const [candidate, step, inputDigest, reason] of [
    [null, 'prepare', 'input-a', 'missing receipt'],
    [{ malformed: true }, 'prepare', 'input-a', 'malformed receipt'],
    [
      { ...receipt, schemaVersion: 2 },
      'prepare',
      'input-a',
      'unsupported receipt schema',
    ],
    [{ ...receipt, step: 'build' }, 'prepare', 'input-a', 'step mismatch'],
    [receipt, 'prepare', 'input-b', 'input digest changed'],
  ]) {
    assert.deepEqual(
      await evaluateReceiptStatus({
        receipt: candidate,
        step,
        inputDigest,
        readOutputDigest,
      }),
      { valid: false, reason, outputTreeDigest: null }
    );
  }
  assert.equal(outputReads, 0);

  assert.deepEqual(
    await evaluateReceiptStatus({
      receipt,
      step: 'prepare',
      inputDigest: 'input-a',
      readOutputDigest: async () => {
        outputReads += 1;
        return 'tree-b';
      },
    }),
    {
      valid: false,
      reason: 'output tree digest changed',
      outputTreeDigest: 'tree-b',
    }
  );
  assert.equal(outputReads, 1);

  assert.deepEqual(
    await evaluateReceiptStatus({
      receipt,
      step: 'prepare',
      inputDigest: 'input-a',
      readOutputDigest,
    }),
    { valid: true, reason: 'receipt hit', outputTreeDigest: 'tree-a' }
  );
  assert.equal(outputReads, 2);
});

test('development build receipts bind the fast chain and invalidate on patch change', async () => {
  const output = value => value.repeat(64);
  const makeReceipt = (step, outputTreeDigest) =>
    createReceipt({
      step,
      inputDigest: output('1'),
      input: { fixture: step },
      toolVersions: { node: 'fixture' },
      outputTreeDigest,
    });
  const receipts = new Map([
    ['extract', makeReceipt('extract', output('a'))],
    ['deps', makeReceipt('deps', output('b'))],
    ['patch', makeReceipt('patch', output('c'))],
    ['libgd', makeReceipt('libgd', output('d'))],
  ]);
  const receiptFor = async step => receipts.get(step) || null;

  const firstBuildInput = {
    ...(await resolvePipelineReceiptInputs({ step: 'build', receiptFor })),
    developmentPreparationSha256: output('e'),
    catalogTreeSha256: output('f'),
  };
  assert.deepEqual(firstBuildInput, {
    patch: output('c'),
    deps: output('b'),
    libgd: output('d'),
    developmentPreparationSha256: output('e'),
    catalogTreeSha256: output('f'),
  });
  assert.ok(Object.values(firstBuildInput).every(Boolean));

  const buildOutput = output('9');
  const buildReceipt = createReceipt({
    step: 'build',
    inputDigest: digestRecord(firstBuildInput),
    input: firstBuildInput,
    toolVersions: { node: 'fixture' },
    outputTreeDigest: buildOutput,
  });
  const unchangedBuildInput = {
    ...(await resolvePipelineReceiptInputs({ step: 'build', receiptFor })),
    developmentPreparationSha256: output('e'),
    catalogTreeSha256: output('f'),
  };
  const unchangedBuildStatus = explainReceipt({
    receipt: buildReceipt,
    step: 'build',
    inputDigest: digestRecord(unchangedBuildInput),
    outputDigest: buildOutput,
  });
  assert.deepEqual(unchangedBuildStatus, {
    valid: true,
    reason: 'receipt hit',
  });
  assert.deepEqual(
    planPipelineExecution({
      target: 'build',
      statusByStep: { build: unchangedBuildStatus },
      automatic: true,
    }),
    { steps: [], hits: ['build'] }
  );

  receipts.set('patch', makeReceipt('patch', output('8')));
  const changedBuildInput = {
    ...(await resolvePipelineReceiptInputs({ step: 'build', receiptFor })),
    developmentPreparationSha256: output('e'),
    catalogTreeSha256: output('f'),
  };
  const changedBuildStatus = explainReceipt({
    receipt: buildReceipt,
    step: 'build',
    inputDigest: digestRecord(changedBuildInput),
    outputDigest: buildOutput,
  });
  assert.deepEqual(changedBuildStatus, {
    valid: false,
    reason: 'input digest changed',
  });
  assert.deepEqual(
    planPipelineExecution({
      target: 'build',
      statusByStep: {
        patch: { valid: true, reason: 'fixture receipt hit' },
        deps: { valid: true, reason: 'fixture receipt hit' },
        libgd: { valid: true, reason: 'fixture receipt hit' },
        build: changedBuildStatus,
      },
      automatic: true,
    }),
    { steps: ['build'], hits: ['patch', 'deps', 'libgd'] }
  );

  receipts.set('build', buildReceipt);
  const auditInput = await resolvePipelineReceiptInputs({
    step: 'audit',
    receiptFor,
  });
  assert.deepEqual(auditInput, {
    extract: output('a'),
    patch: output('8'),
    libgd: output('d'),
    build: buildOutput,
  });
  receipts.set('audit', makeReceipt('audit', output('7')));
  assert.deepEqual(
    await resolvePipelineReceiptInputs({ step: 'prepare', receiptFor }),
    { audit: output('7') }
  );
});

test('patch receipts bind the locked offline external editor inputs', () => {
  assert.match(
    pipelineSource,
    /lockedExternalEditorsManifestSha256:\s*await sha256File\(/
  );
  assert.match(
    pipelineSource,
    /lockedExternalEditorsTreeSha256:\s*\(await computeTreeDigest\(\{[\s\S]*?root: lockedExternalEditorsPath,[\s\S]*?rejectSymlinks: true/
  );
  assert.match(
    pipelineSource,
    /localExternalEditorDerivativesTreeSha256:\s*\(await computeTreeDigest\(\{[\s\S]*?root: localExternalEditorDerivativesPath,[\s\S]*?rejectSymlinks: true/,
    'changing a local external-editor derivative must invalidate the patch receipt'
  );
});

test('development package source uses receipt-bound build, audit and prepare inputs', () => {
  assert.match(
    pipelineSource,
    /case "build":[\s\S]*?receiptInputs\("build"\)[\s\S]*?developmentPreparationSha256[\s\S]*?catalogTreeSha256/
  );
  assert.match(
    pipelineSource,
    /case "audit":[\s\S]*?receiptInputs\("audit"\)/
  );
  assert.match(
    pipelineSource,
    /case "prepare":[\s\S]*?receiptInputs\("prepare"\)/
  );
});

test('test, build and prepare receipts bind the canonical AI tool contract', () => {
  assert.match(
    pipelineSource,
    /const canonicalAiToolsPath = path\.join\([\s\S]*?playmeshDirectory,[\s\S]*?"runtime",[\s\S]*?"ai",[\s\S]*?"tools\.json"/
  );
  for (const step of ['test', 'build', 'prepare']) {
    assert.match(
      pipelineSource,
      new RegExp(
        `case "${step}":[\\s\\S]*?canonicalAiToolsSha256: await sha256File\\(canonicalAiToolsPath\\)`
      ),
      `${step} receipt must invalidate when the canonical AI tool contract changes`
    );
  }
});

test('dependency and libGD cache identities are stable records, not version guesses', () => {
  const first = digestRecord({
    packageLockSha256: 'a'.repeat(64),
    node: 'v22.0.0',
    nodeAbi: '127',
    npm: '10.0.0',
    platform: 'linux',
    arch: 'x64',
  });
  const second = digestRecord({
    arch: 'x64',
    platform: 'linux',
    npm: '10.0.0',
    nodeAbi: '127',
    node: 'v22.0.0',
    packageLockSha256: 'a'.repeat(64),
  });
  assert.equal(first, second);
  const baseLibGdIdentity = {
    schemaVersion: 2,
    kind: 'official-exact-commit-artifact',
    pin: 'gdevelop-v5.6.276',
    revision: 'a'.repeat(40),
    urlIdentity:
      'https://s3.amazonaws.com/gdevelop-gdevelop.js/master/commit/' +
      'a'.repeat(40),
    userDecision: 'not-required',
    files: {
      'libGD.js': { sha256: 'b'.repeat(64), size: 1 },
      'libGD.wasm': { sha256: 'c'.repeat(64), size: 1 },
    },
    pairing: {
      referencedExportCount: 1,
      wasmExportCount: 1,
      wasmImportCount: 0,
    },
  };
  assert.notEqual(
    libGdCacheKey(baseLibGdIdentity),
    libGdCacheKey({
      ...baseLibGdIdentity,
      kind: 'approved-legacy-prepared-exception',
      userDecision: 'B',
    }),
    'libGD source kind must participate in the cache identity'
  );
});

test('disk preflight is injectable and rejects shortage before extraction', async () => {
  await assert.rejects(() =>
    assertAvailableDiskSpace({
      destination: path.resolve('.'),
      requiredBytes: 1024,
      marginBytes: 128,
      statfsImplementation: async () => ({ bavail: 1, bsize: 512 }),
    })
  );
  const result = await assertAvailableDiskSpace({
    destination: path.resolve('.'),
    requiredBytes: 1024,
    marginBytes: 128,
    statfsImplementation: async () => ({ bavail: 4, bsize: 512 }),
  });
  assert.equal(result.minimumBytes, 1152);
});

const makeStoredZip = entries => {
  const localParts = [];
  const centralParts = [];
  let localOffset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name, 'utf8');
    const contents = Buffer.from(entry.contents || '');
    const crc = crc32Bytes(contents);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(contents.length, 18);
    local.writeUInt32LE(contents.length, 22);
    local.writeUInt16LE(name.length, 26);
    localParts.push(local, name, contents);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(contents.length, 20);
    central.writeUInt32LE(contents.length, 24);
    central.writeUInt16LE(name.length, 28);
    const externalAttributes =
      ((entry.name.endsWith('/') ? 0o40755 : 0o100644) << 16) >>> 0;
    central.writeUInt32LE(externalAttributes, 38);
    central.writeUInt32LE(localOffset, 42);
    centralParts.push(central, name);
    localOffset += local.length + name.length + contents.length;
  }
  const centralBytes = Buffer.concat(centralParts);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralBytes.length, 12);
  end.writeUInt32LE(localOffset, 16);
  return Buffer.concat([...localParts, centralBytes, end]);
};

test('safe extraction accepts a normal root directory and checks CRC/layout', async () => {
  const root = await temporaryRoot();
  const archive = path.join(root, 'source.zip');
  const destination = path.join(root, 'output');
  await writeFile(
    archive,
    makeStoredZip([
      { name: 'GDevelop-5.6.269/' },
      { name: 'GDevelop-5.6.269/newIDE/' },
      {
        name: 'GDevelop-5.6.269/newIDE/package.json',
        contents: '{}',
      },
    ])
  );
  await extractZipSafely({
    archivePath: archive,
    destination,
    expectedRoot: 'GDevelop-5.6.269',
    statfsImplementation: async () => ({ bavail: 1024 ** 3, bsize: 4096 }),
  });
  assert.equal(
    await readFile(path.join(destination, 'newIDE', 'package.json'), 'utf8'),
    '{}'
  );
});

test('atomic directory replacement restores the previous target on failed promote', async () => {
  const root = await temporaryRoot();
  const target = path.join(root, 'target');
  await mkdir(target);
  await writeFile(path.join(target, 'sentinel.txt'), 'old');
  await assert.rejects(() =>
    replaceDirectoryAtomically({
      staging: path.join(root, 'missing-staging'),
      target,
    })
  );
  assert.equal(await readFile(path.join(target, 'sentinel.txt'), 'utf8'), 'old');
});

test('source digest excludes only the exact dependency link path', async () => {
  const root = await temporaryRoot();
  await mkdir(path.join(root, 'newIDE', 'app', 'node_modules'), {
    recursive: true,
  });
  await mkdir(path.join(root, 'fixture', 'node_modules'), { recursive: true });
  await mkdir(path.join(root, 'fixture', 'build'), { recursive: true });
  await writeFile(
    path.join(root, 'newIDE', 'app', 'node_modules', 'ignored.txt'),
    'ignored'
  );
  await writeFile(
    path.join(root, 'fixture', 'node_modules', 'tracked.txt'),
    'tracked'
  );
  await writeFile(path.join(root, 'fixture', 'build', 'tracked.txt'), 'tracked');
  const digest = await computeTreeDigest({
    root,
    excludeRelativePaths: new Set(['newIDE/app/node_modules']),
  });
  assert.equal(
    digest.records.some(record =>
      record.path.startsWith('newIDE/app/node_modules')
    ),
    false
  );
  assert.ok(
    digest.records.some(
      record => record.path === 'fixture/node_modules/tracked.txt'
    )
  );
  assert.ok(
    digest.records.some(record => record.path === 'fixture/build/tracked.txt')
  );
});

test('incremental worktree sync preserves unchanged files and removes stale files', async () => {
  const root = await temporaryRoot();
  const source = path.join(root, 'source');
  const destination = path.join(root, 'destination');
  await mkdir(path.join(source, 'nested'), { recursive: true });
  await mkdir(path.join(destination, 'nested'), { recursive: true });
  await writeFile(path.join(source, 'same.txt'), 'same');
  await writeFile(path.join(source, 'nested', 'changed.txt'), 'new');
  await writeFile(path.join(destination, 'same.txt'), 'same');
  await writeFile(path.join(destination, 'nested', 'changed.txt'), 'old');
  await writeFile(path.join(destination, 'stale.txt'), 'stale');
  const before = await stat(path.join(destination, 'same.txt'));
  const result = await synchronizeDirectoryByContent({ source, destination });
  const after = await stat(path.join(destination, 'same.txt'));
  assert.equal(result.copied, 1);
  assert.equal(result.unchanged, 1);
  assert.ok(result.removed >= 1);
  assert.equal(after.mtimeMs, before.mtimeMs);
  assert.equal(
    await readFile(path.join(destination, 'nested', 'changed.txt'), 'utf8'),
    'new'
  );
  await assert.rejects(readFile(path.join(destination, 'stale.txt')), /ENOENT/);
});

test('DAG invalidation is exact for deps and libGD inputs', () => {
  const depsAffected = affectedPipelineSteps('deps');
  assert.deepEqual(depsAffected, [
    'deps',
    'flow',
    'test',
    'build',
    'audit',
    'prepare',
    'package',
    'verify',
  ]);
  assert.equal(depsAffected.includes('patch'), false);
  assert.equal(depsAffected.includes('libgd'), false);

  const libGdAffected = affectedPipelineSteps('libgd');
  assert.deepEqual(libGdAffected, [
    'libgd',
    'build',
    'audit',
    'prepare',
    'package',
    'verify',
  ]);
  assert.equal(libGdAffected.includes('deps'), false);
  assert.equal(libGdAffected.includes('patch'), false);
});

test('fast package planning reuses receipts and never requires quality gates', () => {
  const valid = Object.fromEntries(
    [
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
    ].map(step => [step, { valid: step !== 'package', reason: 'fixture' }])
  );
  const plan = planPipelineExecution({
    target: 'package',
    statusByStep: valid,
    automatic: false,
  });
  assert.deepEqual(plan.steps, ['package']);
  assert.equal(plan.hits.includes('flow'), false);
  assert.equal(plan.hits.includes('test'), false);
  assert.ok(plan.hits.includes('build'));
  assert.ok(plan.hits.includes('prepare'));

  valid.build = { valid: false, reason: 'tampered build' };
  assert.throws(
    () =>
      planPipelineExecution({
        target: 'package',
        statusByStep: valid,
        automatic: false,
      }),
    /requires valid build: tampered build/
  );
});

test('same profile lock rejects concurrent owner and releases cleanly', async () => {
  const root = await temporaryRoot();
  const lockPath = path.join(root, 'profile.lock');
  const release = await acquireProjectLock({
    lockPath,
    profile: 'default',
    command: 'status',
  });
  await assert.rejects(
    acquireProjectLock({ lockPath, profile: 'default', command: 'build' }),
    /profile is locked/
  );
  await release();
  const releaseAgain = await acquireProjectLock({
    lockPath,
    profile: 'default',
    command: 'build',
  });
  await releaseAgain();
});

test('stale profile lock is recovered without weakening live-owner exclusion', async () => {
  const root = await temporaryRoot();
  const lockPath = path.join(root, 'profile.lock');
  await writeFile(
    lockPath,
    `${JSON.stringify({
      pid: 424242,
      profile: 'default',
      command: 'build',
      startedAt: '2026-08-07T00:00:00.000Z',
    })}\n`
  );

  const release = await acquireProjectLock({
    lockPath,
    profile: 'default',
    command: 'status',
    isProcessAlive: () => false,
  });
  const owner = JSON.parse(await readFile(lockPath, 'utf8'));
  assert.equal(owner.pid, process.pid);
  assert.equal(owner.command, 'status');
  assert.equal(typeof owner.token, 'string');
  await release();
});

test('lock release never removes a replacement owner lock', async () => {
  const root = await temporaryRoot();
  const lockPath = path.join(root, 'profile.lock');
  const release = await acquireProjectLock({
    lockPath,
    profile: 'default',
    command: 'build',
  });
  await writeFile(
    lockPath,
    `${JSON.stringify({ pid: process.pid, token: 'replacement-owner' })}\n`
  );
  await release();
  const replacement = JSON.parse(await readFile(lockPath, 'utf8'));
  assert.equal(replacement.token, 'replacement-owner');
});

test('safe extraction rejects duplicate, traversal and CRC-tampered entries', async () => {
  const root = await temporaryRoot();
  const archive = path.join(root, 'invalid.zip');
  const destination = path.join(root, 'output');

  await writeFile(
    archive,
    makeStoredZip([
      { name: 'root/', contents: '' },
      { name: 'root/file.txt', contents: 'one' },
      { name: 'root/file.txt', contents: 'two' },
    ])
  );
  await assert.rejects(
    extractZipSafely({ archivePath: archive, destination, expectedRoot: 'root' }),
    /Duplicate ZIP entry/
  );

  await writeFile(
    archive,
    makeStoredZip([
      { name: 'root/', contents: '' },
      { name: 'root/../escape.txt', contents: 'bad' },
    ])
  );
  await assert.rejects(
    extractZipSafely({ archivePath: archive, destination, expectedRoot: 'root' }),
    /Unsafe ZIP entry path/
  );

  const tampered = makeStoredZip([
    { name: 'root/', contents: '' },
    { name: 'root/file.txt', contents: 'pair-smoke' },
  ]);
  const dataOffset = tampered.indexOf(Buffer.from('pair-smoke'));
  assert.ok(dataOffset > 0);
  tampered[dataOffset] ^= 0xff;
  await writeFile(archive, tampered);
  await assert.rejects(
    extractZipSafely({ archivePath: archive, destination, expectedRoot: 'root' }),
    /CRC mismatch/
  );
});
