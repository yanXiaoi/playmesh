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
const authoritativeCommit = await readFile(
  path.resolve(
    overlayRoot,
    'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshAuthoritativeProjectCommit.js'
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
assert.match(provider, /reason: 'autosave'/);
assert.match(provider, /source: 'system'/);
assert.match(provider, /allocatePlaymeshProjectSnapshot/);
assert.match(authoritativeCommit, /input\.origin !== 'open'/);
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
  commitSection.indexOf('if (shouldBindFileIdentifier)') <
    commitSection.indexOf('await openPlaymeshProject') &&
    commitSection.indexOf('await openPlaymeshProject') <
    commitSection.indexOf('await syncPlaymeshHistory'),
  'same-gameId Save As binding must be established before authoritative current commit'
);
const openSection = provider.slice(
  provider.indexOf('const openAuthoritativeProject'),
  provider.indexOf('const managedStorage')
);
assert.match(
  openSection,
  /await openPlaymeshProjectWithPreparedRestoreRecovery\([\s\S]*loadPlaymeshHistoryCurrentProject/,
  'the initial project open must retain its lifecycle binding'
);
assert.match(
  openSection,
  /openPlaymeshProjectWithPreparedRestoreRecovery\([\s\S]*openProject,[\s\S]*abortPreparedPlaymeshHistoryRestore/,
  'project open must safely abort and retry an orphaned PREPARED restore'
);
assert.match(
  provider,
  /owner: 'project-open'[\s\S]*openAuthoritativeProjectUnderLease/,
  'project open recovery must share the browser project mutation lease'
);
const explicitSaveSection = provider.slice(
  provider.indexOf('onSaveProject: async'),
  provider.indexOf('onChooseSaveProjectAsLocation')
);
assert.match(explicitSaveSection, /shouldBindFileIdentifier: false/);
const saveAsSection = provider.slice(
  provider.indexOf('onSaveProjectAs: async'),
  provider.indexOf('onChangeProjectProperty')
);
assert.match(
  saveAsSection,
  /shouldBindFileIdentifier: origin === 'open'/,
  'Save As retaining gameId must bind its new fileIdentifier'
);
const autosaveSection = provider.slice(
  provider.indexOf('onAutoSaveProject: async'),
  provider.indexOf('getOpenErrorMessage')
);
assert.match(autosaveSection, /shouldBindFileIdentifier: false/);
assert.match(autosaveSection, /tryRunPlaymeshProjectAutosave/);
assert.match(autosaveSection, /historyResult\.historyCreated === false/);
assert.match(autosaveSection, /skipped: 'history_not_created'/);
assert.doesNotMatch(explicitSaveSection, /openPlaymeshProject/);
assert.doesNotMatch(autosaveSection, /openPlaymeshProject/);
assert.match(sourcePolicy, /getChangesGeneration/);
assert.match(sourcePolicy, /createPlaymeshAutosaveController/);
assert.match(sourcePolicy, /autosaveProjectIfNeeded\('periodic'\)/);
assert.match(
  sourcePolicy,
  /generation: getChangesGeneration\(\),\s*trigger,\s*save,/
);
assert.match(sourcePolicy, /60 \* 1000/);
assert.match(sourcePolicy, /usePlaymeshAutosavePreferenceLabel/);
assert.match(serializer, /gameId = ensureGDevelopGameId\(project\)/);
assert.doesNotMatch(serializer, /gameId: project\.getProjectUuid\(\)/);
const serializerPrepare = serializer.slice(
  serializer.indexOf('export const prepareProjectPersistence'),
  serializer.indexOf('export const mirrorPreparedProject')
);
assert.doesNotMatch(serializerPrepare, /putStoredProject/);
assert.doesNotMatch(managedStorageController, /selectPlaymeshInitialProject/);
assert.match(managedStorageController, /activeGameId/);
assert.match(provider, /createPlaymeshAuthoritativeProjectCommit/);
assert.match(authoritativeCommit, /return commitLifecycleAndHistory\(/);
assert.doesNotMatch(
  authoritativeCommit,
  /await commitLifecycleAndHistory\([\s\S]*return undefined/
);
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
assert.match(
  importButton,
  /accept="\.zip,application\/zip,application\/x-zip-compressed,\.json,application\/json"/
);
assert.match(importButton, /sourceFile\.name\.toLowerCase\(\)\.endsWith\('\.json'\)/);
assert.match(importButton, /\{ projectJsonBlob: sourceFile \}/);
assert.match(importButton, /\{ archiveBlob: sourceFile \}/);
assert.match(importButton, /importPortableProjectWithCopyDecision/);
assert.match(historyUi, /restorePlaymeshHistoryToLocalStore/);
assert.match(historyUi, /width: "min\(720px, 72vw\)"/);
assert.match(historyUi, /isMobile \? \{ width: "100vw" \} : \{\}/);
assert.match(historyUi, /<PlaymeshHistoryDiffDialog/);
assert.match(historyDiffDialog, /id="playmesh-history-diff-dialog"/);
assert.match(historyDiffDialog, /onRequestClose=\{onClose\}/);
assert.match(historyUi, /playmeshMessages\.historyErrorEditingSafe/);
assert.match(
  historyUi,
  /error\.code === "gdevelop_revision_conflict"/,
  'an authoritative save conflict must not be presented as a history loading failure'
);
const historyStatusSection = historyUi.slice(
  historyUi.indexOf('const onHistoryStatus'),
  historyUi.indexOf('window.addEventListener', historyUi.indexOf('const onHistoryStatus'))
);
assert.match(
  historyStatusSection,
  /isHistoryRevisionConflict\(detail\.error\)[\s\S]*loadVersions\(\);[\s\S]*return;/
);
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
