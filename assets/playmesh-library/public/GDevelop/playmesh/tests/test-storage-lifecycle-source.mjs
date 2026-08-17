import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const overlayRoot = path.resolve(testDirectory, '../overlays/newIDE/app/src');
const sourcePolicy = await readFile(
  path.resolve(testDirectory, '../scripts/apply-source-policy.mjs'),
  'utf8'
);
const provider = await readFile(
  path.resolve(
    overlayRoot,
    'ProjectsStorage/PlaymeshLocalStorageProvider/index.js'
  ),
  'utf8'
);
const serializer = await readFile(
  path.resolve(
    overlayRoot,
    'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer.js'
  ),
  'utf8'
);
const managedStorageController = await readFile(
  path.resolve(
    overlayRoot,
    'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshManagedProjectStorageController.js'
  ),
  'utf8'
);
const projectPicker = await readFile(
  path.resolve(
    overlayRoot,
    'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshLocalProjectPicker.js'
  ),
  'utf8'
);
const createSection = await readFile(
  path.resolve(
    overlayRoot,
    'MainFrame/EditorContainers/PlaymeshHomePage/PlaymeshCreateSection.js'
  ),
  'utf8'
);
const importButton = await readFile(
  path.resolve(
    overlayRoot,
    'MainFrame/EditorContainers/PlaymeshHomePage/PlaymeshPortableProjectImportButton.js'
  ),
  'utf8'
);
const historyUi = await readFile(
  path.resolve(overlayRoot, 'PlaymeshHistory/UsePlaymeshHistory.js'),
  'utf8'
);
const historyDiffDialog = await readFile(
  path.resolve(overlayRoot, 'PlaymeshHistory/PlaymeshHistoryDiffDialog.js'),
  'utf8'
);
const lifecycleClient = await readFile(
  path.resolve(
    overlayRoot,
    'PlaymeshProjects/PlaymeshProjectLifecycleClient.js'
  ),
  'utf8'
);
const historyClient = await readFile(
  path.resolve(overlayRoot, 'PlaymeshHistory/PlaymeshHistoryClient.js'),
  'utf8'
);

assert.match(
  provider,
  /origin: fileMetadata\.lastModifiedDate \? 'open' : 'create'/
);
assert.match(provider, /generateNewProjectUuid \? 'duplicate' : 'open'/);
assert.match(provider, /reason: 'explicit_save'/);
assert.match(provider, /reason: null/);
assert.match(provider, /allocatePlaymeshProjectSnapshot/);
assert.match(provider, /input\.origin !== 'open'/);
assert.match(
  provider,
  /pendingSaveAsOrigins\.get\(fileIdentifier\) \|\| 'create'/
);
assert.doesNotMatch(
  provider,
  /pendingSaveAsOrigins\.get\(fileIdentifier\) \|\| 'open'/
);
assert.match(provider, /project\.getProjectUuid\(\)/);
assert.match(provider, /getProjectAllocationMessageKey/);
assert.match(provider, /storageAllocationUnauthorized/);
assert.match(provider, /storageAllocationNotFound/);
assert.match(provider, /storageAllocationConflict/);
assert.match(provider, /storageAllocationLocked/);
assert.match(provider, /storageAllocationNetwork/);
assert.match(provider, /storageAllocationTimeout/);
assert.match(provider, /storageAllocationProtocol/);
assert.match(provider, /storageAllocationGeneric/);
assert.ok(
  provider.indexOf("code === 'gdevelop_project_allocation_locked'") <
    provider.indexOf('if (status === 409)'),
  'the allocation lock code must be localized before the generic 409 mapping'
);
assert.match(
  provider,
  /return getPlaymeshMessage\(key, \{ requestId \}\);/
);
assert.doesNotMatch(provider, /\bid: key,/);
assert.doesNotMatch(provider, /\bmessage: getPlaymeshMessage\(/);
assert.doesNotMatch(provider, /playmesh\.gdevelop\.localProject\.saveFailed/);
assert.doesNotMatch(
  provider,
  /Unable to save the Playmesh local project\. Check that Playmesh developer mode is available\./
);
assert.match(provider, /onChangeProjectProperty:[\s\S]*updatePlaymeshProject/);
assert.match(
  provider,
  /const listAuthoritativeProjects[\s\S]*listPlaymeshProjects/
);
assert.match(
  provider,
  /openAuthoritativeProject[\s\S]*loadPlaymeshHistoryCurrentProject/
);
assert.match(provider, /diagnostics=\{projectList\.diagnostics\}/);
assert.match(provider, /activeGameId: response\.activeGameId/);
assert.match(provider, /getPlaymeshProjectOpenDiagnostic/);
for (const field of ['operation', 'status', 'code', 'requestId']) {
  assert.match(provider, new RegExp(`${field}=\\$\\{`));
}
assert.match(provider, /replace\(\/\\\?\[\^\\s\]\*\/g, ''\)/);
assert.doesNotMatch(provider, /getPlaymeshInitialProjectFileMetadata/);
assert.doesNotMatch(provider, /selectPlaymeshInitialProject/);
assert.doesNotMatch(provider, /deletePlaymeshProject/);
assert.doesNotMatch(provider, /persistProjectWithSnapshot/);
const commitSection = provider.slice(
  provider.indexOf('const commitLifecycleAndHistory'),
  provider.indexOf('const dispatchProjectListDiagnostics')
);
assert.ok(
  commitSection.indexOf('await openPlaymeshProject') <
    commitSection.indexOf('await syncPlaymeshHistory'),
  'App lifecycle must be established before authoritative current commit'
);
assert.match(serializer, /gameId = ensureGDevelopGameId\(project\)/);
assert.doesNotMatch(serializer, /gameId: project\.getProjectUuid\(\)/);
const serializerPrepare = serializer.slice(
  serializer.indexOf('export const prepareProjectPersistence'),
  serializer.indexOf('export const mirrorPreparedProject')
);
assert.doesNotMatch(serializerPrepare, /putStoredProject/);
assert.doesNotMatch(managedStorageController, /selectPlaymeshInitialProject/);
assert.match(managedStorageController, /activeGameId/);
assert.doesNotMatch(managedStorageController, /listCachedProjects/);
assert.doesNotMatch(managedStorageController, /mirrorPreparedProject/);
assert.doesNotMatch(managedStorageController, /source: 'cache'/);
assert.match(projectPicker, /projectPickerDiagnosticsTitle/);
assert.doesNotMatch(projectPicker, /projectPickerClearCache/);
assert.doesNotMatch(projectPicker, /projectSource === 'cache'/);
assert.doesNotMatch(projectPicker, /<Trans>Delete<\/Trans>/);
assert.match(createSection, /PlaymeshPortableProjectImportButton/);
assert.match(createSection, /DownloadFileSaveAsDialog/);
assert.match(createSection, /homeExportSourceZip/);
assert.match(createSection, /listAuthoritativeProjects/);
assert.match(createSection, /hasSuccessfulProjectList/);
assert.match(createSection, /projectListUnavailable/);
assert.match(
  createSection,
  /setProjectListUnavailable\(true\);[\s\S]*setProjectListError/
);
assert.match(
  createSection,
  /hasSuccessfulProjectList && !projectListUnavailable/
);
assert.doesNotMatch(
  createSection,
  /catch \(error\) \{[\s\S]{0,240}setLocalProjects\(\[\]\)/
);
assert.match(createSection, /deletePlaymeshProject/);
assert.match(createSection, /closeProject/);
assert.match(
  createSection,
  /onOpenProject\([\s\S]*ignorePersistedEditorTabs: true/
);
assert.match(
  createSection,
  /<PlaymeshPortableProjectImportButton\s+onOpenProject=\{onOpenProject\}/
);
assert.doesNotMatch(createSection, /PreferencesContext/);
assert.doesNotMatch(createSection, /PlaymeshOfficialExamplesDialog/);
assert.doesNotMatch(createSection, /homeOfficialExamples/);
assert.match(importButton, /accept="\.zip,application\/zip/);
assert.match(importButton, /importPortableProjectWithCopyDecision/);
assert.match(historyUi, /restorePlaymeshHistoryToLocalStore/);
assert.match(historyUi, /width: "min\(720px, 72vw\)"/);
assert.match(historyUi, /isMobile \? \{ width: "100vw" \} : \{\}/);
assert.match(historyUi, /<PlaymeshHistoryDiffDialog/);
assert.match(historyDiffDialog, /id="playmesh-history-diff-dialog"/);
assert.match(historyDiffDialog, /onRequestClose=\{onClose\}/);
assert.match(historyUi, /playmeshMessages\.historyErrorEditingSafe/);
for (const client of [lifecycleClient, historyClient]) {
  assert.match(client, /credentials: 'same-origin'/);
  assert.match(client, /requestId/);
  assert.match(client, /status/);
  assert.match(client, /operation/);
  assert.match(client, /response\.headers\.get\('x-request-id'\)/);
}
assert.match(lifecycleClient, /projects\.forEach\(\(rawProject, index\)/);
assert.match(lifecycleClient, /validatedProjects\.push\(\{ identity, hasCurrent \}\)/);
assert.match(lifecycleClient, /validatedActiveGameId = null/);
assert.match(lifecycleClient, /createManagedProjectListDiagnostic/);
assert.match(
  provider,
  /response\.projects\.find\([\s\S]*project\.identity\.gameId === projectRef\.gameId/
);
assert.match(sourcePolicy, /storageProviderName === 'PlaymeshLocal'/);
assert.match(
  sourcePolicy,
  /leave startup on the App-backed project list without automatic opening/
);

process.stdout.write('GDevelop storage/history UI source invariants passed.\n');
