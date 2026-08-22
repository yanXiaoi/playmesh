import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourceDirectory = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshAi'
);
const sourceOf = name => readFile(path.join(sourceDirectory, name), 'utf8');

const dialogSource = await sourceOf('PlaymeshAiApprovalDialog.js');
const panelSource = await sourceOf('PlaymeshAiPanel.js');
const containerSource = await sourceOf('PlaymeshAiEditorContainer.js');
const executorSource = await sourceOf('PlaymeshAiExecutor.js');
const adapterSource = await sourceOf('PlaymeshAiEditorFunctionAdapter.js');
const wrappersSource = await sourceOf('PlaymeshAiLocalToolWrappers.js');
const eventPayloadExecutorSource = await sourceOf(
  'PlaymeshAiEventPayloadExecutor.js'
);
const protocolSource = await sourceOf('PlaymeshAiProtocol.js');
const clientSource = await sourceOf('PlaymeshAiClient.js');
const controllerSource = await sourceOf('PlaymeshAiSessionController.js');

// Approval requests are modal, explicit and serialized. A polling refresh may
// not replace the request currently shown to the user, and double clicks may
// not issue two decisions.
assert.match(dialogSource, /approvals\.find\(item => item\.approvalId === pinnedApprovalId\)/);
assert.match(dialogSource, /decisionInFlightRef\.current/);
assert.match(dialogSource, /cannotBeDismissed/);
assert.match(dialogSource, /dangerLevel=\{approval\.risk === 'high' \? 'danger' : 'warning'\}/);
for (const decision of [
  'onApproveOnce',
  'onApproveProject',
  'onApproveAlways',
  'onReject',
]) {
  assert.match(dialogSource, new RegExp(`decide\\(${decision}\\)`));
}
assert.match(panelSource, /<PlaymeshAiApprovalDialog/);
assert.doesNotMatch(panelSource, /isPlaymeshAiCallCommitting|committing/);

// Approval mode is one shared, session-backed setting above both Chat and
// Agent views. The normal state is deliberately just the official accessible
// Toggle and its current mode, with no explanatory card or persistent copy.
assert.match(panelSource, /import Toggle from '\.\.\/UI\/Toggle';/);
assert.equal(panelSource.match(/<Toggle\b/g)?.length, 1);
const tabsIndex = panelSource.indexOf('<Tabs');
const approvalModeIndex = panelSource.indexOf('id="playmesh-ai-approval-mode"');
const firstViewBranchIndex = panelSource.indexOf("{view === 'agent'");
assert.ok(
  tabsIndex >= 0 &&
    approvalModeIndex > tabsIndex &&
    firstViewBranchIndex > approvalModeIndex
);
assert.match(
  panelSource,
  /id="playmesh-ai-approval-mode"[\s\S]*?aria-label=\{t\(playmeshMessages\.aiApprovalModeTitle\)\}/
);
assert.match(panelSource, /labelPosition="right"/);
const approvalModeToggleStart = panelSource.indexOf('<Toggle', approvalModeIndex);
const approvalModeToggleEnd = panelSource.indexOf('/>', approvalModeToggleStart);
const approvalModeToggleSource = panelSource.slice(
  approvalModeToggleStart,
  approvalModeToggleEnd
);
assert.match(
  approvalModeToggleSource,
  /playmeshMessages\.aiApprovalModeAlways/
);
assert.match(approvalModeToggleSource, /playmeshMessages\.aiApprovalModeRequest/);
assert.match(panelSource, /toggled=\{approvalMode === 'always_allow'\}/);
assert.match(
  panelSource,
  /approvalModeStatus === 'saving'[\s\S]*?approvalModeStatus === 'uncertain'/
);
assert.match(panelSource, /role="status"[\s\S]*?aria-live="polite"/);
assert.match(panelSource, /width: '100%'[\s\S]*?minWidth: 0[\s\S]*?boxSizing: 'border-box'/);
assert.match(panelSource, /approvalModeSection:[\s\S]*?display: 'flex'[\s\S]*?flexWrap: 'wrap'/);
assert.match(panelSource, /overflowWrap: 'anywhere'/);
assert.doesNotMatch(panelSource, /whiteSpace:\s*'nowrap'/);
assert.doesNotMatch(
  panelSource,
  /aiApprovalMode(?:RequestDescription|AlwaysDescription|GrantsUnaffected)/
);
assert.match(containerSource, /sessionState\.session\.approvalMode/);
assert.match(
  containerSource,
  /onFetchNewlyAddedResources:\s*props\.resourceManagementProps\.onFetchNewlyAddedResources/
);
assert.match(
  containerSource,
  /executorRef\.current\.onFetchNewlyAddedResources =\s*props\.resourceManagementProps\.onFetchNewlyAddedResources/
);
assert.match(
  executorSource,
  /options\.onFetchNewlyAddedResources = this\.onFetchNewlyAddedResources/
);
assert.match(
  containerSource,
  /useEnsureExtensionInstalled\(\{[\s\S]*?project: props\.project,[\s\S]*?i18n: props\.i18n/
);
assert.match(containerSource, /ensureExtensionInstalled,\s*onWillInstallExtension/);
assert.doesNotMatch(
  [containerSource, adapterSource, wrappersSource].join('\n'),
  /ensureExtensionInstalled:\s*async\s*\([^)]*\)\s*=>\s*\{\}/
);
assert.doesNotMatch(adapterSource, /extension_not_installed_locally/);
assert.doesNotMatch(wrappersSource, /capability_install_incomplete/);
assert.doesNotMatch(eventPayloadExecutorSource, /event_payload_apply_failed/);
assert.match(
  executorSource,
  /DEFERRED_PROJECT_MUTATION_TOOLS\.has\(definition\.name\)[\s\S]*?_assertExecutionIdentity\([\s\S]*?enterNonCancellableExecution\(\)/
);
assert.match(containerSource, /updateApprovalMode\(/);
assert.match(containerSource, /reconcileApprovalMode\(/);
assert.match(
  containerSource,
  /await sessionControllerRef\.current\.updateApprovalMode\([\s\S]*?await refreshApprovals\(\)/
);
assert.match(
  containerSource,
  /await sessionControllerRef\.current\.reconcileApprovalMode\([\s\S]*?await refreshApprovals\(\)/
);
assert.match(controllerSource, /this\.client\.updateApprovalMode\(/);
assert.match(controllerSource, /this\.client\.getSession\(/);
assert.match(controllerSource, /approval_mode_update_not_applied/);
assert.match(controllerSource, /approval_mode_state_uncertain/);
assert.match(controllerSource, /approval_mode_operation_stale/);
assert.match(controllerSource, /approval_mode_operation_aborted/);
assert.match(
  controllerSource,
  /sessionEpoch: this\.sessionEpoch,[\s\S]*?gameId,[\s\S]*?editorSessionId: session\.editorSessionId/
);
assert.match(
  controllerSource,
  /_assertApprovalModeOperationCurrent\(operationSnapshot, signal\);[\s\S]*?this\.session = updated/
);
assert.match(containerSource, /approvalModeOperationGenerationRef/);
assert.match(containerSource, /approval_mode_operation_stale/);
assert.match(containerSource, /approval_mode_operation_aborted/);
assert.match(protocolSource, /PLAYMESH_AI_SESSION_PROTOCOL_VERSION = '4\.0\.0'/);
assert.match(protocolSource, /approvalMode: validatePlaymeshAiApprovalMode/);
assert.match(
  clientSource,
  /editor-settings\/\$\{encodeURIComponent\([\s\S]*?\)\}\/approval-mode/
);
assert.doesNotMatch(
  [panelSource, containerSource, controllerSource, clientSource].join('\n'),
  /localStorage|sessionStorage/
);

// All approval actions share one wrapping container, so long English labels
// cannot force the mobile dialog wider than its viewport.
assert.match(dialogSource, /flexWrap: 'wrap'/);
assert.match(dialogSource, /gap: 8/);
assert.match(dialogSource, /width: '100%'/);
assert.match(dialogSource, /minWidth: 0/);
assert.match(dialogSource, /role="group"/);
assert.doesNotMatch(dialogSource, /secondaryActions=\{/);

// Project-wide always-allowed operations are available from both Chat and
// Agent. The panel owns one shared, accessible view of the grants instead of
// maintaining separate approval UI or state per tab.
assert.match(panelSource, /id="playmesh-ai-approval-grants"/);
assert.match(
  panelSource,
  /aria-label=\{t\(playmeshMessages\.aiApprovalGrantsTitle\)\}/
);
assert.doesNotMatch(
  panelSource,
  /\{view === 'agent' && \(\s*<Accordion costlyBody>\s*<AccordionHeader>\s*<Text size="block-title">\s*\{t\(playmeshMessages\.aiApprovalGrantsTitle\)\}/
);
assert.equal(
  panelSource.match(/onRevokeApprovalGrant\(grant\.grantId\)/g)?.length,
  1,
  'Chat and Agent must reuse the same grant revocation path.'
);
assert.equal(
  panelSource.match(/onClick=\{onRefreshApprovalGrants\}/g)?.length,
  1,
  'Chat and Agent must reuse the same grant refresh path.'
);
const grantSectionStart = panelSource.indexOf(
  'id="playmesh-ai-approval-grants"'
);
const grantSectionEnd = panelSource.indexOf('</Accordion>', grantSectionStart);
const grantSectionSource = panelSource.slice(
  grantSectionStart,
  grantSectionEnd
);
assert.doesNotMatch(grantSectionSource, /aiApprovalGrantsDescription/);
assert.doesNotMatch(grantSectionSource, /<LineStackLayout/);
assert.match(
  panelSource,
  /approvalGrantRow:[\s\S]*?display: 'flex'[\s\S]*?flexWrap: 'wrap'[\s\S]*?minWidth: 0/
);
assert.match(
  panelSource,
  /approvalGrantIdentity:[\s\S]*?flex: '1 1 180px'[\s\S]*?minWidth: 0[\s\S]*?maxWidth: '100%'/
);
assert.match(
  panelSource,
  /approvalGrantAction:[\s\S]*?flex: '0 0 auto'[\s\S]*?marginLeft: 'auto'/
);
assert.match(grantSectionSource, /overflowWrap: 'anywhere'/);

// Paste-and-run clears stale text before reading the clipboard, restores the
// exact newly pasted request before execution, and never clears that request
// after execution/copying the return status.
const pasteStart = containerSource.indexOf('const pasteAndExecute');
const clearStart = containerSource.indexOf('const clearManualInput', pasteStart);
assert.ok(pasteStart >= 0 && clearStart > pasteStart);
const pasteSource = containerSource.slice(pasteStart, clearStart);
const clearIndex = pasteSource.indexOf("setManualInput('')");
const readIndex = pasteSource.indexOf('await readPlaymeshText');
const restoreIndex = pasteSource.indexOf('setManualInput(result.value)');
const executeIndex = pasteSource.indexOf('await executeManualInput(result.value)');
assert.ok(clearIndex >= 0 && clearIndex < readIndex);
assert.ok(readIndex < restoreIndex && restoreIndex < executeIndex);
assert.equal(
  pasteSource.slice(restoreIndex + 1).includes("setManualInput('')"),
  false,
  'the pasted request must remain visible after execution'
);
const copyStart = containerSource.indexOf('const copyReturnStatus');
const executeStart = containerSource.indexOf('const executeManualInput', copyStart);
assert.ok(copyStart >= 0 && executeStart > copyStart);
assert.doesNotMatch(
  containerSource.slice(copyStart, executeStart),
  /setManualInput\(/
);

// AI modifies the live project. The UI source must not grow a second project
// serializer/clone/history/reload path.
assert.doesNotMatch(
  [containerSource, executorSource].join('\n'),
  /SerializerElement|unserializeFrom|cloneGDevelopProject|syncPlaymeshHistory|pendingJournal|commitEvidence|persistAfter|reloadProject/
);

console.log('PlayMesh AI UI boundary tests passed.');
