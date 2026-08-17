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
