import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  parseExpectedAiState,
  sha256Bytes,
  validateSourcePolicyOutputManifest,
  verifyBidirectionalOverlayOutput,
  verifyExpectedAiFeatureState,
  verifyOutputManifestFreezeState,
  verifyOverlayTreeDigest,
  verifyRecordedSourcePolicyOutputs,
} from '../scripts/source-policy-verifier-lib.mjs';
import { classifyPlaymeshTestFiles } from '../scripts/layout-verifier-lib.mjs';
import {
  parseLibGdProvenance,
  verifyLibGdBytesAgainstProvenance,
} from '../scripts/webide-provenance.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const temporaryRoot = await mkdtemp(
  path.join(tmpdir(), 'playmesh-release-verifier-')
);

const writeRelative = async (root, relativePath, content) => {
  const filePath = path.join(root, ...relativePath.split('/'));
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, content);
};

const pendingManifestSource = () => ({
  schemaVersion: 1,
  upstream: {
    tag: 'v5.6.269',
    commit: 'a'.repeat(40),
  },
  overlay: { treeSha256: 'pending' },
  generatedFiles: [
    {
      relativePath: 'newIDE/app/src/PlaymeshShared/Generated.js',
      postPatchSha256: 'pending',
    },
  ],
  patchedOfficialFiles: [
    {
      relativePath: 'newIDE/app/src/MainFrame/index.js',
      upstreamGitBlobSha: 'b'.repeat(40),
      postPatchSha256: 'pending',
    },
  ],
});

try {
  const overlayDirectory = path.join(temporaryRoot, 'overlay');
  const sourceRoot = path.join(temporaryRoot, 'source');
  const overlayRelativePath =
    'newIDE/app/src/PlaymeshFeature/PlaymeshCurrent.js';
  const generatedRelativePath =
    'newIDE/app/src/ExportAndShare/GeneratedOfficial.js';
  const generatedPlaymeshRelativePath =
    'newIDE/app/src/PlaymeshShared/Generated.js';
  await writeRelative(overlayDirectory, overlayRelativePath, 'canonical\n');
  await writeRelative(sourceRoot, overlayRelativePath, 'canonical\n');
  await writeRelative(sourceRoot, generatedRelativePath, 'generated\n');
  await writeRelative(sourceRoot, generatedPlaymeshRelativePath, 'generated\n');

  const generatedFiles = [
    { relativePath: generatedRelativePath },
    { relativePath: generatedPlaymeshRelativePath },
  ];
  const matchingOverlay = await verifyBidirectionalOverlayOutput({
    overlayDirectory,
    sourceRoot,
    generatedFiles,
  });
  assert.equal(matchingOverlay.overlayFiles.length, 1);
  assert.equal(matchingOverlay.ownedFiles.length, 2);

  await assert.rejects(
    verifyBidirectionalOverlayOutput({
      overlayDirectory,
      sourceRoot,
      generatedFiles: [{ relativePath: overlayRelativePath }],
    }),
    /Overlay and generated output paths overlap/
  );

  const staleRelativePath = 'newIDE/app/src/PlaymeshRetired/legacy.js';
  await writeRelative(sourceRoot, staleRelativePath, 'stale\n');
  await assert.rejects(
    verifyBidirectionalOverlayOutput({
      overlayDirectory,
      sourceRoot,
      generatedFiles,
    }),
    /Unexpected stale Playmesh-owned files:[\s\S]*legacy\.js/
  );
  await rm(path.join(sourceRoot, ...staleRelativePath.split('/')));

  await writeRelative(sourceRoot, overlayRelativePath, 'mutated\n');
  await assert.rejects(
    verifyBidirectionalOverlayOutput({
      overlayDirectory,
      sourceRoot,
      generatedFiles,
    }),
    /target bytes differ/
  );
  await writeRelative(sourceRoot, overlayRelativePath, 'canonical\n');
  await rm(path.join(sourceRoot, ...overlayRelativePath.split('/')));
  await assert.rejects(
    verifyBidirectionalOverlayOutput({
      overlayDirectory,
      sourceRoot,
      generatedFiles,
    }),
    /target is missing/
  );
  await writeRelative(sourceRoot, overlayRelativePath, 'canonical\n');

  const manifest = validateSourcePolicyOutputManifest(pendingManifestSource());
  const overlayDevelopmentResult = await verifyOverlayTreeDigest({
    manifest,
    overlayDirectory,
    allowPending: true,
  });
  assert.match(overlayDevelopmentResult.sha256, /^[a-f0-9]{64}$/);
  assert.equal(overlayDevelopmentResult.warnings.length, 1);
  await assert.rejects(
    verifyOverlayTreeDigest({ manifest, overlayDirectory }),
    /overlay\.treeSha256 is pending/
  );
  const wrongOverlayManifest = {
    ...manifest,
    overlay: { treeSha256: 'c'.repeat(64) },
  };
  await assert.rejects(
    verifyOverlayTreeDigest({
      manifest: wrongOverlayManifest,
      overlayDirectory,
    }),
    /Overlay tree digest mismatch/
  );

  assert.throws(
    () => verifyOutputManifestFreezeState({ manifest }),
    /Source-policy output manifest is not frozen/
  );
  assert.equal(
    verifyOutputManifestFreezeState({ manifest, allowPending: true }).warnings
      .length,
    3
  );

  const patchedDigest = sha256Bytes(Buffer.from('patched\n'));
  const generatedDigest = sha256Bytes(Buffer.from('generated\n'));
  const observedOutputs = {
    patchedOfficialFiles: [
      {
        relativePath: manifest.patchedOfficialFiles[0].relativePath,
        upstreamGitBlobSha: manifest.patchedOfficialFiles[0].upstreamGitBlobSha,
        postPatchSha256: patchedDigest,
      },
    ],
    generatedFiles: [
      {
        relativePath: manifest.generatedFiles[0].relativePath,
        postPatchSha256: generatedDigest,
      },
    ],
  };
  assert.throws(
    () =>
      verifyRecordedSourcePolicyOutputs({
        manifest,
        ...observedOutputs,
      }),
    /postPatchSha256 is pending/
  );
  assert.equal(
    verifyRecordedSourcePolicyOutputs({
      manifest,
      ...observedOutputs,
      allowPending: true,
    }).warnings.length,
    2
  );

  const frozenManifest = {
    ...manifest,
    overlay: { treeSha256: overlayDevelopmentResult.sha256 },
    patchedOfficialFiles: manifest.patchedOfficialFiles.map(entry => ({
      ...entry,
      postPatchSha256: patchedDigest,
    })),
    generatedFiles: manifest.generatedFiles.map(entry => ({
      ...entry,
      postPatchSha256: generatedDigest,
    })),
  };
  assert.deepEqual(
    verifyRecordedSourcePolicyOutputs({
      manifest: frozenManifest,
      ...observedOutputs,
    }).warnings,
    []
  );
  assert.throws(
    () =>
      verifyRecordedSourcePolicyOutputs({
        manifest: {
          ...frozenManifest,
          generatedFiles: frozenManifest.generatedFiles.map(entry => ({
            ...entry,
            postPatchSha256: 'd'.repeat(64),
          })),
        },
        ...observedOutputs,
      }),
    /post-patch digest mismatch/
  );
  assert.throws(
    () =>
      verifyRecordedSourcePolicyOutputs({
        manifest: frozenManifest,
        ...observedOutputs,
        generatedFiles: [],
      }),
    /Generated files set differs[\s\S]*Missing records/
  );
  assert.throws(
    () =>
      verifyRecordedSourcePolicyOutputs({
        manifest: frozenManifest,
        ...observedOutputs,
        patchedOfficialFiles: [
          ...observedOutputs.patchedOfficialFiles,
          {
            relativePath: 'newIDE/app/src/MainFrame/Unexpected.js',
            upstreamGitBlobSha: 'f'.repeat(40),
            postPatchSha256: 'f'.repeat(64),
          },
        ],
      }),
    /Patched official files set differs[\s\S]*Unexpected records/
  );
  assert.throws(
    () =>
      verifyRecordedSourcePolicyOutputs({
        manifest: frozenManifest,
        ...observedOutputs,
        patchedOfficialFiles: observedOutputs.patchedOfficialFiles.map(
          entry => ({
            ...entry,
            upstreamGitBlobSha: 'e'.repeat(40),
          })
        ),
      }),
    /upstream Git blob SHA differs/
  );
  assert.throws(
    () =>
      verifyRecordedSourcePolicyOutputs({
        manifest: frozenManifest,
        ...observedOutputs,
        generatedFiles: [
          observedOutputs.generatedFiles[0],
          observedOutputs.generatedFiles[0],
        ],
      }),
    /Observed Generated files records contain duplicate path/
  );

  const unsafeManifest = pendingManifestSource();
  unsafeManifest.generatedFiles[0].relativePath = '../PlaymeshEscape.js';
  assert.throws(
    () => validateSourcePolicyOutputManifest(unsafeManifest),
    /unsafe or non-canonical/
  );
  const duplicateManifest = pendingManifestSource();
  duplicateManifest.generatedFiles.push({
    ...duplicateManifest.generatedFiles[0],
  });
  assert.throws(
    () => validateSourcePolicyOutputManifest(duplicateManifest),
    /duplicate path/
  );

  assert.equal(
    parseExpectedAiState([
      'node',
      'audit',
      '--expect-ai',
      'session-bootstrap',
    ]),
    'session-bootstrap'
  );
  assert.throws(
    () => parseExpectedAiState(['node', 'audit']),
    /Required exactly once/
  );
  assert.throws(
    () => parseExpectedAiState(['node', 'audit', '--expect-ai', 'enabled']),
    /Required exactly once/
  );
  assert.throws(
    () =>
      parseExpectedAiState([
        'node',
        'audit',
        '--expect-ai',
        'session-bootstrap',
        '--expect-ai',
        'session-bootstrap',
      ]),
    /Required exactly once/
  );
  assert.equal(
    verifyExpectedAiFeatureState({
      featureFlagsSource: `
const FEATURE_POLICY_FORMAT_VERSION = '1.0.0';
const EVENTS_PATH_TEMPLATE = '/events';
export const getIsPlaymeshAiEnabled = () => {
  const policy = window.__PLAYMESH_GDEVELOP_AI_FEATURE_POLICY__;
  if (!policy) return false;
  const policyRecord = policy;
  return policyRecord.enabled === true;
};
export default getIsPlaymeshAiEnabled;
`,
      expectedAiState: 'session-bootstrap',
    }),
    'session-bootstrap'
  );
  assert.throws(
    () =>
      verifyExpectedAiFeatureState({
        featureFlagsSource: 'export const isPlaymeshAiEnabled = false;\n',
        expectedAiState: 'session-bootstrap',
      }),
    /must not contain a build-time boolean assignment/
  );
  assert.throws(
    () =>
      verifyExpectedAiFeatureState({
        featureFlagsSource: 'export const getIsPlaymeshAiEnabled = () => true;\n',
        expectedAiState: 'session-bootstrap',
      }),
    /missing the Developer Mode session-bootstrap contract/
  );

  const classifiedTestFiles = classifyPlaymeshTestFiles([
    { relativePath: 'test-release-verifiers.mjs' },
    { relativePath: 'fixtures/source-policy-module-contracts.json' },
    { relativePath: 'fixtures/history/v1/restore-case.json' },
  ]);
  assert.deepEqual(
    classifiedTestFiles.executableTestFiles.map(file => file.relativePath),
    ['test-release-verifiers.mjs']
  );
  assert.deepEqual(
    classifiedTestFiles.fixtureDataFiles.map(file => file.relativePath),
    [
      'fixtures/source-policy-module-contracts.json',
      'fixtures/history/v1/restore-case.json',
    ]
  );
  assert.throws(
    () =>
      classifyPlaymeshTestFiles([
        { relativePath: 'test-valid.mjs' },
        { relativePath: 'release-verifiers.mjs' },
      ]),
    /must be named test-\*\.mjs/
  );
  assert.throws(
    () =>
      classifyPlaymeshTestFiles([
        { relativePath: 'test-valid.mjs' },
        { relativePath: 'fixtures/test-hidden.mjs' },
      ]),
    /fixture must use an approved data extension/
  );

  const pairedJavascript = Buffer.from(
    'var wasmBinaryFile="libGD.wasm";Module["asm"]["a"]();\n',
    'utf8'
  );
  const wasmExporting = exportName =>
    Buffer.from([
      0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
      0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
      0x03, 0x02, 0x01, 0x00,
      0x07, 0x05, 0x01, 0x01, exportName.charCodeAt(0), 0x00, 0x00,
      0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    ]);
  const pairedWasm = wasmExporting('a');
  const createLibGdProvenance = ({
    javascriptBytes = pairedJavascript,
    wasmBytes = pairedWasm,
    ...overrides
  } = {}) => ({
    kind: 'approved-legacy-prepared-exception',
    source: temporaryRoot,
    upstreamVersion: '5.6.269',
    files: {
      'libGD.js': {
        sha256: sha256Bytes(javascriptBytes),
        size: javascriptBytes.byteLength,
      },
      'libGD.wasm': {
        sha256: sha256Bytes(wasmBytes),
        size: wasmBytes.byteLength,
      },
    },
    userDecision: 'B',
    ...overrides,
  });
  const validLibGdProvenance = createLibGdProvenance();
  assert.equal(
    parseLibGdProvenance(validLibGdProvenance).kind,
    'approved-legacy-prepared-exception'
  );
  const officialLibGdProvenance = {
    ...validLibGdProvenance,
    kind: 'official-exact-commit-artifact',
    source:
      'https://s3.amazonaws.com/gdevelop-gdevelop.js/master/commit/' +
      'a'.repeat(40),
    upstreamVersion: '5.6.276',
    userDecision: 'not-required',
  };
  assert.equal(
    parseLibGdProvenance(officialLibGdProvenance).kind,
    'official-exact-commit-artifact'
  );
  assert.throws(
    () =>
      parseLibGdProvenance({
        ...officialLibGdProvenance,
        source:
          'https://s3.amazonaws.com/gdevelop-gdevelop.js/master/latest',
      }),
    /exact official GDevelop commit artifact URL/
  );
  assert.equal(
    parseLibGdProvenance({
      ...validLibGdProvenance,
      source:
        '/mnt/f/Project/flutter/playmesh/work/gdevelop-webide-prepared-5.6.269',
    }).source,
    '/mnt/f/Project/flutter/playmesh/work/gdevelop-webide-prepared-5.6.269'
  );
  assert.throws(
    () =>
      parseLibGdProvenance(
        Object.fromEntries(
          Object.entries(validLibGdProvenance).filter(
            ([key]) => key !== 'userDecision'
          )
        )
      ),
    /must contain exactly/
  );
  assert.throws(
    () =>
      parseLibGdProvenance({
        ...validLibGdProvenance,
        kind: 'legacy-auto-fallback',
      }),
    /kind must be approved-legacy-prepared-exception or official-exact-commit-artifact/
  );
  assert.throws(
    () =>
      parseLibGdProvenance({
        ...validLibGdProvenance,
        files: {
          ...validLibGdProvenance.files,
          'libGD.js': {
            ...validLibGdProvenance.files['libGD.js'],
            sha256: 'wrong',
          },
        },
      }),
    /lowercase SHA-256 digest/
  );
  assert.throws(
    () =>
      verifyLibGdBytesAgainstProvenance({
        provenance: {
          ...validLibGdProvenance,
          files: {
            ...validLibGdProvenance.files,
            'libGD.js': {
              ...validLibGdProvenance.files['libGD.js'],
              sha256: 'f'.repeat(64),
            },
          },
        },
        javascriptBytes: pairedJavascript,
        wasmBytes: pairedWasm,
      }),
    /libGD\.js SHA-256 mismatch/
  );
  assert.throws(
    () =>
      parseLibGdProvenance({
        ...validLibGdProvenance,
        files: {
          ...validLibGdProvenance.files,
          'libGD.wasm': {
            ...validLibGdProvenance.files['libGD.wasm'],
            size: 0,
          },
        },
      }),
    /size must be a positive safe integer/
  );
  assert.throws(
    () =>
      parseLibGdProvenance({
        ...validLibGdProvenance,
        userDecision: 'A',
      }),
    /userDecision must be B/
  );
  const mismatchedWasm = wasmExporting('b');
  assert.throws(
    () =>
      verifyLibGdBytesAgainstProvenance({
        provenance: createLibGdProvenance({ wasmBytes: mismatchedWasm }),
        javascriptBytes: pairedJavascript,
        wasmBytes: mismatchedWasm,
      }),
    /JS\/WASM pair mismatch/
  );
  assert.throws(
    () => {
      const tamperedJavascript = Buffer.from(pairedJavascript);
      tamperedJavascript[tamperedJavascript.length - 1] ^= 1;
      verifyLibGdBytesAgainstProvenance({
        provenance: validLibGdProvenance,
        javascriptBytes: tamperedJavascript,
        wasmBytes: pairedWasm,
      });
    },
    /libGD\.js SHA-256 mismatch/
  );
  assert.throws(
    () =>
      classifyPlaymeshTestFiles([
        { relativePath: 'test-valid.mjs' },
        { relativePath: 'helpers/test-hidden.mjs' },
      ]),
    /Only playmesh\/tests\/fixtures\/\*\* data files may be nested/
  );
  for (const unsafeFixturePath of [
    'fixtures/../test-escape.mjs',
    'fixtures\\escape.json',
    '/fixtures/escape.json',
    'fixtures//escape.json',
  ]) {
    assert.throws(
      () =>
        classifyPlaymeshTestFiles([
          { relativePath: 'test-valid.mjs' },
          { relativePath: unsafeFixturePath },
        ]),
      /unsafe or non-canonical/
    );
  }

  const productionAuditPath = path.join(
    testDirectory,
    'test-production-build-audit.mjs'
  );
  const productionAuditSource = await readFile(productionAuditPath, 'utf8');
  for (const provenanceGate of [
    /loadFrozenProvenanceContext/,
    /verifyPatchedSourceInputs/,
    /writeBuildProvenance/,
    /verifyBuildProvenance/,
    /--source-archive/,
    /--source-policy-manifest/,
    /--overlay/,
    /--libgd-kind/,
    /--libgd-source/,
    /--libgd-js-sha256/,
    /--libgd-wasm-sha256/,
    /verifyLibGdFilesAgainstProvenance/,
    /PLAYMESH_AI_SESSION_PROTOCOL_VERSION/,
    /playmesh-ai-approval-mode/,
  ]) {
    assert.match(productionAuditSource, provenanceGate);
  }
  assert.ok(
    productionAuditSource.indexOf('verifyPatchedSourceInputs({') <
      productionAuditSource.indexOf('writeBuildProvenance({'),
    'build provenance must be written only after patched source verification'
  );
  assert.doesNotMatch(
    productionAuditSource,
    /fallback|gdevelop-webide-prepared-5\.6\.269/i,
    'production audit must not infer a legacy libGD source or silently fall back'
  );
  const missingAiExpectation = spawnSync(
    process.execPath,
    [productionAuditPath, '--build', temporaryRoot, '--lock', temporaryRoot],
    { encoding: 'utf8' }
  );
  assert.notEqual(missingAiExpectation.status, 0);
  assert.match(
    `${missingAiExpectation.stdout}${missingAiExpectation.stderr}`,
    /--expect-ai session-bootstrap/
  );
  const forbiddenPendingOverride = spawnSync(
    process.execPath,
    [
      productionAuditPath,
      '--build',
      temporaryRoot,
      '--lock',
      temporaryRoot,
      '--expect-ai',
      'session-bootstrap',
      '--allow-pending-output-manifest',
    ],
    { encoding: 'utf8' }
  );
  assert.notEqual(forbiddenPendingOverride.status, 0);
  assert.match(
    `${forbiddenPendingOverride.stdout}${forbiddenPendingOverride.stderr}`,
    /forbids --allow-pending-output-manifest/
  );

  // 静态核对提供快速反馈；干净树实际重放仍由 apply 末尾的运行时全集核对负责。
  const playmeshDirectory = path.resolve(testDirectory, '..');
  const applySource = await readFile(
    path.join(playmeshDirectory, 'scripts', 'apply-source-policy.mjs'),
    'utf8'
  );
  const repositoryManifest = validateSourcePolicyOutputManifest(
    JSON.parse(
      await readFile(
        path.join(playmeshDirectory, 'source-policy-output-manifest.json'),
        'utf8'
      )
    )
  );
  const pairPattern =
    /relativePath:\s*['"]([^'"]+)['"],\s*expectedGitBlobSha:\s*['"]([a-f0-9]{40})['"]/g;
  const literalPairs = [...applySource.matchAll(pairPattern)].map(match => ({
    relativePath: match[1],
    upstreamGitBlobSha: match[2],
  }));
  const assertionPaths = new Set();
  const assertionBlockPattern =
    /await assertOfficialSourceFile\(\{([\s\S]*?)\n\}\);/g;
  for (const assertionBlock of applySource.matchAll(assertionBlockPattern)) {
    const match = [...assertionBlock[1].matchAll(pairPattern)];
    assert.equal(
      match.length,
      1,
      'official source assertion must contain one literal path/SHA pair'
    );
    assertionPaths.add(match[0][1]);
  }
  const applyPatchPairs = literalPairs
    .filter(entry => !assertionPaths.has(entry.relativePath))
    .sort((left, right) => left.relativePath.localeCompare(right.relativePath));
  const manifestPatchPairs = repositoryManifest.patchedOfficialFiles
    .map(entry => ({
      relativePath: entry.relativePath,
      upstreamGitBlobSha: entry.upstreamGitBlobSha,
    }))
    .sort((left, right) => left.relativePath.localeCompare(right.relativePath));
  assert.deepEqual(
    applyPatchPairs,
    manifestPatchPairs,
    'apply-source-policy literal patch path/preimage pairs must match the output manifest'
  );

  process.stdout.write(
    'Release verifier self-tests passed: stale overlays, content drift, pending/wrong digests, incomplete patch records, unsafe manifests, non-bootstrap AI policy and production pending overrides all fail closed.\n'
  );
} finally {
  // 仅清理由本测试通过 mkdtemp 创建且带固定前缀的临时目录。
  assert.match(path.basename(temporaryRoot), /^playmesh-release-verifier-/);
  await rm(temporaryRoot, { recursive: true, force: true });
}
