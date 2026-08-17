import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  assertManifestMatchesWebIdeLock,
  collectOutputRecordsFromSourceTree,
  loadSourcePolicyOutputManifest,
  verifyStaticModuleImportContract,
  verifyBidirectionalOverlayOutput,
  verifyOverlayTreeDigest,
  verifyRecordedSourcePolicyOutputs,
} from '../scripts/source-policy-verifier-lib.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const sourceArgumentIndex = process.argv.indexOf('--source');
if (sourceArgumentIndex === -1 || !process.argv[sourceArgumentIndex + 1]) {
  throw new Error(
    'Usage: node test-source-policy-output.mjs --source <patched GDevelop root> [--allow-pending-output-manifest]'
  );
}
const sourceRoot = path.resolve(process.argv[sourceArgumentIndex + 1]);
const allowPendingOutputManifest = process.argv.includes(
  '--allow-pending-output-manifest'
);

const gitBlobSha = bytes => {
  const header = Buffer.from(`blob ${bytes.length}\0`, 'utf8');
  return createHash('sha1')
    .update(header)
    .update(bytes)
    .digest('hex');
};

const walkFiles = async directory => {
  const output = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) output.push(...(await walkFiles(entryPath)));
    else if (entry.isFile()) output.push(entryPath);
  }
  return output;
};

const readRelativeModuleSource = async (importerPath, specifier) => {
  const modulePath = path.resolve(path.dirname(importerPath), specifier);
  const candidates = [
    modulePath,
    `${modulePath}.js`,
    `${modulePath}.jsx`,
    path.join(modulePath, 'index.js'),
    path.join(modulePath, 'index.jsx'),
  ];
  for (const candidate of candidates) {
    try {
      return { path: candidate, source: await readFile(candidate, 'utf8') };
    } catch (error) {
      if (error && (error.code === 'ENOENT' || error.code === 'EISDIR')) {
        continue;
      }
      throw error;
    }
  }
  throw new Error(
    `Unable to resolve Playmesh AI relative import ${JSON.stringify(
      specifier
    )} from ${importerPath}`
  );
};

const overlayDirectory = path.join(playmeshDirectory, 'overlays');
const outputManifest = await loadSourcePolicyOutputManifest(
  path.join(playmeshDirectory, 'source-policy-output-manifest.json')
);
const webIdeLock = JSON.parse(
  await readFile(path.join(playmeshDirectory, 'webide-lock.json'), 'utf8')
);
assertManifestMatchesWebIdeLock({ manifest: outputManifest, lock: webIdeLock });
const overlayOutput = await verifyBidirectionalOverlayOutput({
  overlayDirectory,
  sourceRoot,
  generatedFiles: outputManifest.generatedFiles,
});
const overlayTree = await verifyOverlayTreeDigest({
  manifest: outputManifest,
  overlayDirectory,
  allowPending: allowPendingOutputManifest,
});
const observedOutputs = await collectOutputRecordsFromSourceTree({
  manifest: outputManifest,
  sourceRoot,
});
const recordedOutputs = verifyRecordedSourcePolicyOutputs({
  manifest: outputManifest,
  ...observedOutputs,
  allowPending: allowPendingOutputManifest,
});
const pendingWarnings = [...overlayTree.warnings, ...recordedOutputs.warnings];
if (pendingWarnings.length > 0) {
  process.stderr.write(
    `\n=== DEVELOPMENT OVERRIDE: OUTPUT MANIFEST IS PENDING ===\n${pendingWarnings
      .map(warning => `- ${warning}`)
      .join('\n')}\n` +
      'This run is not release evidence. Freeze every digest and rerun without the override.\n' +
      '========================================================\n\n'
  );
}

assert.deepEqual(
  await readFile(
    path.join(sourceRoot, 'newIDE/app/src/PlaymeshShared/GameManifest.js')
  ),
  await readFile(
    path.resolve(playmeshDirectory, '../../developer/playmesh-game-manifest.js')
  ),
  'canonical game manifest must be copied byte-for-byte into the WebIDE source'
);

// Node 单测不一定会加载全部编辑器模块，因此这里按用于构建的精确补丁树核对
// Playmesh AI 对 GDevelop 源模块的 default/named 导入合同。
const playmeshAiDirectory = path.join(sourceRoot, 'newIDE/app/src/PlaymeshAi');
let checkedPlaymeshAiImports = 0;
let checkedPlaymeshAiTypeOnlyImports = 0;
let checkedPlaymeshAiCommonJsImports = 0;
const playmeshAiImportContractErrors = [];
for (const importerPath of await walkFiles(playmeshAiDirectory)) {
  if (!/\.jsx?$/.test(importerPath)) continue;
  const importerSource = await readFile(importerPath, 'utf8');
  const importPattern = /\bimport\s+([^;]+?)\s+from\s+['"](\.\.\/[^'"]+)['"]\s*;/g;
  for (const match of importerSource.matchAll(importPattern)) {
    const [, clause, specifier] = match;
    const target = await readRelativeModuleSource(importerPath, specifier);
    const contract = verifyStaticModuleImportContract({
      importClause: clause,
      moduleSource: target.source,
    });
    if (contract.missingDefault) {
      playmeshAiImportContractErrors.push(
        `${path.relative(
          sourceRoot,
          importerPath
        )} imports a default from ${specifier}, but ${path.relative(
          sourceRoot,
          target.path
        )} has no default export`
      );
    }
    for (const importedName of contract.missingNamed) {
      playmeshAiImportContractErrors.push(
        `${path.relative(
          sourceRoot,
          importerPath
        )} imports named ${importedName} from ${specifier}, but ${path.relative(
          sourceRoot,
          target.path
        )} does not export it`
      );
    }
    if (
      contract.parsedImport.declarationKind !== 'value' ||
      contract.parsedImport.namedImports.some(
        binding => binding.importKind !== 'value'
      )
    ) {
      checkedPlaymeshAiTypeOnlyImports += 1;
    }
    if (contract.moduleExports.usesCommonJs) {
      checkedPlaymeshAiCommonJsImports += 1;
    }
    checkedPlaymeshAiImports += 1;
  }
}
assert.ok(
  checkedPlaymeshAiImports > 0,
  'no Playmesh AI source imports checked'
);
assert.ok(
  checkedPlaymeshAiTypeOnlyImports > 0,
  'no Playmesh AI Flow type-only imports checked'
);
assert.ok(
  checkedPlaymeshAiCommonJsImports > 0,
  'no Playmesh AI CommonJS imports checked'
);
assert.deepEqual(
  playmeshAiImportContractErrors,
  [],
  `Playmesh AI source import contracts failed:\n${playmeshAiImportContractErrors.join(
    '\n'
  )}`
);

const canonicalCases = [
  {
    source: path.resolve(
      playmeshDirectory,
      '../../developer/gdevelop-authority-bootstrap.js'
    ),
    generated: path.join(
      sourceRoot,
      'newIDE/app/src/PlaymeshShared/GDevelopAuthorityBootstrapSource.js'
    ),
  },
  {
    source: path.resolve(
      playmeshDirectory,
      '../../developer/gdevelop-multiplayer-bridge.js'
    ),
    generated: path.join(
      sourceRoot,
      'newIDE/app/src/PlaymeshShared/GDevelopMultiplayerBridgeSource.js'
    ),
  },
  {
    source: path.resolve(
      playmeshDirectory,
      '../../developer/gdevelop-app-runtime-debugger-client.js'
    ),
    generated: path.join(
      sourceRoot,
      'newIDE/app/src/PlaymeshShared/GDevelopAppRuntimeDebuggerClientSource.js'
    ),
  },
];
for (const item of canonicalCases) {
  const generated = await readFile(item.generated, 'utf8');
  const match = generated.match(
    /const source: string = ([\s\S]+);\nexport default source;\n$/
  );
  assert.ok(match, `invalid generated canonical module: ${item.generated}`);
  assert.equal(JSON.parse(match[1]), await readFile(item.source, 'utf8'));
}

for (const [relativePath, expectedSha] of [
  [
    'Extensions/Multiplayer/JsExtension.js',
    'bd558e1626bb9096eac9b6d094a5fabfd10e60c4',
  ],
  [
    'Extensions/Multiplayer/messageManager.ts',
    '146a9b0bf321c71f3a227b10cf97028d539ae52e',
  ],
  [
    'Extensions/Multiplayer/peer.js',
    '0abdf49a5335afc03c8977d7072a9755a27a7b94',
  ],
  [
    'Extensions/Multiplayer/multiplayerVariablesManager.ts',
    '6bfc0160afe40ffe09124b6203d9fe3c5eb56677',
  ],
  [
    'Extensions/Multiplayer/multiplayerobjectruntimebehavior.ts',
    '05d77a67b5b70661e0fd30c33e02bc39094ad184',
  ],
]) {
  const bytes = await readFile(path.join(sourceRoot, relativePath));
  assert.equal(gitBlobSha(bytes), expectedSha, `${relativePath} was modified`);
  assert.doesNotMatch(bytes.toString('utf8'), /playmesh/i);
}
assert.doesNotMatch(
  await readFile(
    path.join(
      sourceRoot,
      'newIDE/app/src/ExportAndShare/BrowserExporters/BrowserHTML5Export.js'
    ),
    'utf8'
  ),
  /playmesh/i,
  'generic Browser HTML exporter must stay Playmesh-free'
);

const patchedMultiplayerToolsSource = await readFile(
  path.join(sourceRoot, 'Extensions/Multiplayer/multiplayertools.ts'),
  'utf8'
);
assert.equal(
  (patchedMultiplayerToolsSource.match(
    /notifyOfficialLobbyFrameClosed\(\)/g
  ) || []).length,
  1,
  'the official lobby close boundary must notify the Playmesh backend exactly once'
);
assert.match(
  patchedMultiplayerToolsSource,
  /gdjs\.multiplayerComponents\.removeLobbiesContainer\(runtimeScene\);\s+getPlaymeshLobbyBackend\(\)\?\.notifyOfficialLobbyFrameClosed\(\);/,
  'the optional Playmesh close notification must run only after the official lobby root is removed'
);

const brandedMainMenuSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/MainFrame/MainMenu.js'),
  'utf8'
);
assert.doesNotMatch(brandedMainMenuSource, /t`GDevelop 5`/);
assert.doesNotMatch(brandedMainMenuSource, /t`About GDevelop`/);
assert.match(brandedMainMenuSource, /t`Playmesh Visual Editor`/);
assert.match(brandedMainMenuSource, /t`About Playmesh Visual Editor`/);
const brandedAboutDialogSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/MainFrame/AboutDialog.js'),
  'utf8'
);
assert.doesNotMatch(brandedAboutDialogSource, /<Trans>About GDevelop<\/Trans>/);
assert.match(
  brandedAboutDialogSource,
  /<Trans>About Playmesh Visual Editor<\/Trans>/
);
const brandedTitlebarSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/MainFrame/ProjectTitlebar.js'),
  'utf8'
);
assert.doesNotMatch(brandedTitlebarSource, /'GDevelop 5'/);
assert.match(brandedTitlebarSource, /'Playmesh Visual Editor'/);

const patchedMainFrameSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/MainFrame/index.js'),
  'utf8'
);
assert.doesNotMatch(
  patchedMainFrameSource,
  /getPlaymeshInitialProjectFileMetadata/,
  'startup must not consume the App active project automatically'
);
assert.doesNotMatch(
  patchedMainFrameSource,
  /getRecentProjectFiles\(\)\[0\]/,
  'startup must stay on the App project list until explicit user selection'
);
assert.match(
  patchedMainFrameSource,
  /configureNewProjectActionsForProfile/,
  'normal profile configuration must remain after startup auto-open removal'
);
assert.match(
  patchedMainFrameSource,
  /onOpenPlaymeshProject: openFromFileMetadataWithStorageProvider/,
  'example import must use the existing explicit MainFrame open controller'
);
assert.match(
  patchedMainFrameSource,
  /ignorePersistedEditorTabs\?: boolean/,
  'MainFrame must expose an in-memory tab restore policy for explicit App project selection'
);
assert.match(
  patchedMainFrameSource,
  /options && options\.ignorePersistedEditorTabs[\s\S]*openSceneOrProjectManager/,
  'explicit App project selection must reuse native fresh-project initialization'
);
assert.match(
  patchedMainFrameSource,
  /else if \(\s*currentProject &&\s*hasAPreviousSaveForEditorTabsState/,
  'ordinary opens and same-session refreshes must retain the official persisted-tab path'
);
const patchedBaseEditorSource = await readFile(
  path.join(
    sourceRoot,
    'newIDE/app/src/MainFrame/EditorContainers/BaseEditor.js'
  ),
  'utf8'
);
assert.match(
  patchedBaseEditorSource,
  /onOpenRecentFile:[\s\S]*ignorePersistedEditorTabs\?: boolean/,
  'the home editor callback must type the explicit selection option without changing metadata'
);

const patchedProvidersSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/MainFrame/Providers.js'),
  'utf8'
);
assert.match(
  patchedProvidersSource,
  /PlaymeshDisabledCommercialProviders/,
  'unsupported commerce stores must be disabled at the mounted Provider seam'
);

const patchedProjectPropertiesSource = await readFile(
  path.join(
    sourceRoot,
    'newIDE/app/src/ProjectManager/ProjectPropertiesDialog.js'
  ),
  'utf8'
);
for (const requiredPattern of [
  /\| 'playmesh';/,
  /PlaymeshProjectConfigSection/,
  /visible=\{currentTab === 'playmesh'\}/,
  /saveAfterOfficialApply\(\{/,
  /officialApplySucceeded: true/,
  /gameId: packageName/,
  /keepOpen: !playmeshSaved/,
]) {
  assert.match(
    patchedProjectPropertiesSource,
    requiredPattern,
    `project properties is missing the App-sidecar Playmesh tab contract ${requiredPattern}`
  );
}
assert.doesNotMatch(
  patchedProjectPropertiesSource,
  /project\.set(?:GameType|Playmesh|Multiplayer)/,
  'Playmesh game type must remain in the App sidecar, not gdProject JSON'
);
const patchedProjectManagerSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/ProjectManager/index.js'),
  'utf8'
);
assert.match(patchedProjectManagerSource, /!options\.keepOpen/);

const croppedNewObjectDialogSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/AssetStore/NewObjectDialog.js'),
  'utf8'
);
for (const forbiddenPattern of [
  /import \{ Tabs \} from '\.\.\/UI\/Tabs'/,
  /import \{ AssetStore,/,
  /CustomObjectPackResults/,
  /useResponsiveWindowSize/,
  /getNewObjectDialogDefaultTab/,
  /setCurrentTab/,
  /setSelectedCustomObjectEnumeratedMetadata/,
]) {
  assert.doesNotMatch(
    croppedNewObjectDialogSource,
    forbiddenPattern,
    `cropped NewObjectDialog retains dead asset-store symbol ${forbiddenPattern}`
  );
}
assert.match(
  croppedNewObjectDialogSource,
  /import \{ type AssetStoreInterface \} from '\.';/
);
assert.match(
  croppedNewObjectDialogSource,
  /React\.useState<'asset-store' \| 'new-object'>\(\s*'new-object'\s*\)/,
  'cropped NewObjectDialog tab state must preserve the official Flow union'
);
assert.match(
  await readFile(
    path.join(sourceRoot, 'newIDE/app/src/AssetStore/NewObjectFromScratch.js'),
    'utf8'
  ),
  /document\.baseURI \|\| window\.location\.href/,
  'installed object icon URL must use a non-null browser base'
);
const croppedObjectStoreSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/AssetStore/ObjectStoreContext.js'),
  'utf8'
);
assert.doesNotMatch(
  croppedObjectStoreSource,
  /\bgetObjectsRegistry\b/,
  'cropped ObjectStoreContext retains the disabled online registry import'
);
assert.doesNotMatch(
  croppedObjectStoreSource,
  /Pre-fetching objects from extension store|Loaded .* objects from the extension store/,
  'disabled ObjectStore must not emit expected empty-store info logs'
);
const patchedSearchSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/UI/Search/UseSearchItem.js'),
  'utf8'
);
assert.doesNotMatch(patchedSearchSource, /Indexed .* items in/);
assert.match(
  patchedSearchSource,
  /console\.error\('Error while indexing items: ', error\)/,
  'search failures must stay observable after timing info is silenced'
);
const patchedStructuredSearchSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/UI/Search/UseSearchStructuredItem.js'),
  'utf8'
);
assert.doesNotMatch(patchedStructuredSearchSource, /Indexed .*items in/s);
assert.match(
  patchedStructuredSearchSource,
  /console\.error\('Error while indexing items: ', error\)/,
  'structured search failures must stay observable after timing info is silenced'
);
const croppedExtensionServiceSource = await readFile(
  path.join(sourceRoot, 'newIDE/app/src/Utils/GDevelopServices/Extension.js'),
  'utf8'
);
for (const forbiddenSymbol of [
  'ExtensionHeaderWithTagsAsString',
  'SerializedExtensionWithTagsAsString',
  'adaptBehaviorHeader',
]) {
  assert.doesNotMatch(
    croppedExtensionServiceSource,
    new RegExp(`\\b${forbiddenSymbol}\\b`),
    `cropped extension service retains dead symbol ${forbiddenSymbol}`
  );
}

process.stdout.write(
  `GDevelop source-policy replay verified ${
    overlayOutput.overlayFiles.length
  } byte-identical overlays with a bidirectional ${
    overlayOutput.ownedFiles.length
  }-file Playmesh ownership set, ${checkedPlaymeshAiImports} Playmesh AI import contracts, the canonical game manifest, two generated canonical modules, five hash-locked untouched official Multiplayer files and an untouched generic exporter.\n`
);
