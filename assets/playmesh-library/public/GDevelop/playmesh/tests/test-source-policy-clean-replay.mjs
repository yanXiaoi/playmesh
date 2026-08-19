import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const workDirectory = path.join(repositoryRoot, 'work');
const playmeshDirectory = path.resolve(testDirectory, '..');
const webIdeLock = JSON.parse(
  await readFile(path.join(playmeshDirectory, 'webide-lock.json'), 'utf8')
);
const outputManifest = JSON.parse(
  await readFile(
    path.join(playmeshDirectory, 'source-policy-output-manifest.json'),
    'utf8'
  )
);
const upstreamVersion = webIdeLock.upstream.tag.slice(1);
const upstreamBlobSha = relativePath => {
  const record = outputManifest.patchedOfficialFiles.find(
    entry => entry.relativePath === relativePath
  );
  assert.ok(record, `missing output manifest record for ${relativePath}`);
  return record.upstreamGitBlobSha;
};
const zipArgumentIndex = process.argv.indexOf('--zip');
const sourceZip = path.resolve(
  zipArgumentIndex === -1
    ? path.join(workDirectory, `GDevelop-${upstreamVersion}.zip`)
    : process.argv[zipArgumentIndex + 1] || ''
);
const allowPendingOutputManifest = process.argv.includes(
  '--allow-pending-output-manifest'
);
const applySourcePolicy = path.resolve(
  testDirectory,
  '../scripts/apply-source-policy.mjs'
);
const verifySourcePolicyOutput = path.resolve(
  testDirectory,
  'test-source-policy-output.mjs'
);
const sourceDependentVerifiers = [
  {
    path: path.resolve(testDirectory, 'test-ai-tool-contract-source.mjs'),
    label: 'official GDevelop v12 AI tool contract snapshot',
  },
  {
    path: path.resolve(
      testDirectory,
      'test-source-policy-module-contracts.mjs'
    ),
    label: 'real pinned GDevelop module contracts',
  },
  {
    path: path.resolve(testDirectory, 'test-multiplayer-runtime-seams.mjs'),
    label: 'Multiplayer lowest-I/O seam contract',
  },
  {
    path: path.resolve(testDirectory, 'test-zero-cloud-resource-source.mjs'),
    label: 'zero-cloud browser resource contract',
  },
  {
    path: path.resolve(
      testDirectory,
      'test-browser-persistence-boundary.mjs'
    ),
    label: 'local BrowserSW-only persistence and dependency boundary',
  },
  {
    path: path.resolve(
      testDirectory,
      'test-external-resource-editors.mjs'
    ),
    label: 'official offline browser external-editor contracts',
  },
  {
    path: path.resolve(
      testDirectory,
      'test-pixi-blob-scene-reload-source.mjs'
    ),
    label: 'Blob image parser and SceneEditor resource reload contract',
  },
  {
    path: path.resolve(
      testDirectory,
      'test-official-runtime-ui-contracts.mjs'
    ),
    label: 'official Multiplayer and Player Authentication UI state machines',
  },
];

const run = (command, args) =>
  new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: repositoryRoot,
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      stdout += chunk;
    });
    child.stderr.on('data', chunk => {
      stderr += chunk;
    });
    child.once('error', reject);
    child.once('close', code => resolve({ code, stdout, stderr }));
  });

const gitBlobSha = bytes => {
  const header = Buffer.from(`blob ${bytes.length}\0`, 'utf8');
  return createHash('sha1')
    .update(header)
    .update(bytes)
    .digest('hex');
};

const sha256File = async filePath =>
  createHash('sha256')
    .update(await readFile(filePath))
    .digest('hex');

await stat(sourceZip);
const temporaryRoot = await mkdtemp(
  path.join(workDirectory, 'gdevelop-source-policy-clean-replay-')
);
try {
  let extraction = await run('tar', ['-xf', sourceZip, '-C', temporaryRoot]);
  if (extraction.code !== 0) {
    extraction = await run('unzip', [
      '-o',
      '-q',
      sourceZip,
      '-d',
      temporaryRoot,
    ]);
  }
  assert.equal(
    extraction.code,
    0,
    `Unable to extract the pinned GDevelop source ZIP:\n${extraction.stderr}`
  );

  const sourceRoot = path.join(temporaryRoot, `GDevelop-${upstreamVersion}`);
  const browserAppPath = path.join(sourceRoot, 'newIDE/app/src/BrowserApp.js');
  const mainFramePath = path.join(
    sourceRoot,
    'newIDE/app/src/MainFrame/index.js'
  );
  assert.equal(
    gitBlobSha(await readFile(browserAppPath)),
    upstreamBlobSha('newIDE/app/src/BrowserApp.js'),
    'the replay must start from the pinned official BrowserApp preimage'
  );
  assert.equal(
    gitBlobSha(await readFile(mainFramePath)),
    upstreamBlobSha('newIDE/app/src/MainFrame/index.js'),
    'the replay must start from the pinned official MainFrame preimage'
  );

  const firstReplay = await run(process.execPath, [
    applySourcePolicy,
    '--source',
    sourceRoot,
  ]);
  assert.equal(
    firstReplay.code,
    0,
    `Clean source-policy replay failed:\n${firstReplay.stdout}\n${
      firstReplay.stderr
    }`
  );
  for (const marker of [
    'Patched newIDE/app/src/BrowserApp.js',
    'Patched newIDE/app/src/ProjectManager/ProjectPropertiesDialog.js',
    'Patched newIDE/app/src/ProjectManager/index.js',
    'Patched newIDE/app/src/MainFrame/UnsavedChangesContext.js',
    'Patched newIDE/app/src/ProjectsStorage/index.js',
    'Patched newIDE/app/src/MainFrame/Preferences/PreferencesDialog.js',
    'Patched newIDE/app/src/MainFrame/index.js',
    'Patched newIDE/app/src/Utils/GDevelopServices/ApiConfigs.js',
    'GDevelop source policy applied successfully.',
  ]) {
    assert.match(firstReplay.stdout, new RegExp(marker.replaceAll('.', '\\.')));
  }
  if (allowPendingOutputManifest) {
    assert.match(firstReplay.stderr, /OUTPUT MANIFEST IS PENDING/);
  } else {
    assert.doesNotMatch(
      firstReplay.stderr,
      /PLAYMESH RELEASE BLOCKED|OUTPUT MANIFEST IS PENDING/,
      'a release-frozen clean replay must not require pending-output overrides'
    );
  }

  const browserPostPatchSha256 = await sha256File(browserAppPath);
  const mainFramePostPatchSha256 = await sha256File(mainFramePath);
  assert.match(browserPostPatchSha256, /^[a-f0-9]{64}$/);
  assert.match(mainFramePostPatchSha256, /^[a-f0-9]{64}$/);
  assert.notEqual(
    gitBlobSha(await readFile(browserAppPath)),
    upstreamBlobSha('newIDE/app/src/BrowserApp.js')
  );
  assert.notEqual(
    gitBlobSha(await readFile(mainFramePath)),
    upstreamBlobSha('newIDE/app/src/MainFrame/index.js')
  );

  for (const verifier of sourceDependentVerifiers) {
    const verification = await run(process.execPath, [
      verifier.path,
      '--source',
      sourceRoot,
      ...(allowPendingOutputManifest
        ? ['--allow-pending-output-manifest']
        : []),
    ]);
    assert.equal(
      verification.code,
      0,
      `${verifier.label} failed on the clean replay tree:\n${
        verification.stdout
      }\n${verification.stderr}`
    );
  }

  const releaseVerification = await run(process.execPath, [
    verifySourcePolicyOutput,
    '--source',
    sourceRoot,
    ...(allowPendingOutputManifest
      ? ['--allow-pending-output-manifest']
      : []),
  ]);
  assert.equal(
    releaseVerification.code,
    0,
    `release verification must accept the frozen clean replay tree:\n${
      releaseVerification.stdout
    }\n${releaseVerification.stderr}`
  );

  const secondReplay = await run(process.execPath, [
    applySourcePolicy,
    '--source',
    sourceRoot,
  ]);
  assert.notEqual(
    secondReplay.code,
    0,
    'an already patched or polluted tree must not be patched a second time'
  );
  assert.match(
    `${secondReplay.stdout}\n${secondReplay.stderr}`,
    /changed upstream\. Expected [a-f0-9]{40}, got [a-f0-9]{40}|Copying the locked (?:piskel|jfxr|yarn) editor tree failed/
  );

  process.stdout.write(
    (allowPendingOutputManifest ? firstReplay.stderr : '') +
    `GDevelop source-policy clean replay passed with source-dependent product contracts; BrowserApp=${browserPostPatchSha256}, MainFrame=${mainFramePostPatchSha256}; ${
      allowPendingOutputManifest
        ? 'pending output digests were reported as development candidates'
        : 'every output digest is frozen and verified'
    }, and a second/polluted replay is rejected.\n`
  );
} finally {
  // 仅清理由本测试通过 mkdtemp 在 workspace/work 下创建的固定前缀目录。
  assert.equal(path.dirname(temporaryRoot), path.resolve(workDirectory));
  assert.match(
    path.basename(temporaryRoot),
    /^gdevelop-source-policy-clean-replay-/
  );
  await rm(temporaryRoot, { recursive: true, force: true });
}
