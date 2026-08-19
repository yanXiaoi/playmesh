import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const overlayDirectory = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshLocalization'
);

let sessionSource = await readFile(
  path.join(overlayDirectory, 'PlaymeshLocalizationSession.js'),
  'utf8'
);
const stripLocalizationSessionFlowTypes = source =>
  source
    .replace(/^\/\/ @flow\s*/, '')
    .replace(/import type \{ PlaymeshMessageKey \} from '[^']+';\s*/, '')
    .replace(
      /export type PlaymeshMessageArgument =[\s\S]*?type MixedRecord = \{ \+\[string\]: mixed \};\s*/,
      ''
    )
    .replace(
      /\n  _fetch: PlaymeshLocalizationFetcher;[\s\S]*?\n  _state: PlaymeshLocalizationState;\n/,
      '\n'
    )
    .replace(
      /([A-Za-z][A-Za-z0-9_]*)(?:\?)?\s*:\s*\??(?:mixed|string|number|boolean|Response|PlaymeshMessageKey|PlaymeshLocalizationFetchOptions|PlaymeshLocalizationListener|PlaymeshLocalizationState|PlaymeshLocalizationSnapshot|CachedPlaymeshLocalizationSnapshot|PreparedLanguageOptions|PreparedPlaymeshLanguage|PlaymeshMessageArguments|PlaymeshLocalizationOptions|MixedRecord|PlaymeshLocalizationStorage)/g,
      '$1'
    )
    .replace(
      /([A-Za-z][A-Za-z0-9_]*)\s*:\s*(?:Array|Set|Promise)<[^;=,)]+>/g,
      '$1'
    )
    .replace(/const result:\s*\{ \[string\]: string \}/g, 'const result')
    .replace(
      /}\s*:\s*(?:PlaymeshLocalizationOptions|PreparedLanguageOptions)\s*=/g,
      '} ='
    )
    .replace(
      /\)\s*:\s*(?:\(\(\) => void\)|\??[A-Za-z][A-Za-z0-9_]*(?:<[^=]+>)?)\s*=>/g,
      ') =>'
    )
    .replace(/\(value: MixedRecord\)/g, 'value')
    .replace(/\((JSON\.parse\([\s\S]*?\)): mixed\)/g, '$1')
    .replace(/\(await response\.json\(\): mixed\)/g, 'await response.json()')
    .replace(
      /export const playmeshLocalizationSession: PlaymeshLocalizationSession =/,
      'export const playmeshLocalizationSession ='
    );

sessionSource = stripLocalizationSessionFlowTypes(sessionSource).replace(
  "import { selectLanguageOrLocale } from '../Utils/Language';",
  `const selectLanguageOrLocale = (languageOrLocale, defaultLanguage) => {
      if (languageOrLocale === 'zh_CN') return 'zh_CN';
      if (languageOrLocale.startsWith('en')) return 'en';
      return defaultLanguage;
    };`
);

assert.doesNotMatch(
  sessionSource,
  /import type|export type|PlaymeshMessageKey|PlaymeshLocalizationState|:\s*(?:mixed|string|number|boolean|Response)(?:[,;)])/
);
const localization = await import(`data:text/javascript;base64,${Buffer.from(
  sessionSource
).toString('base64')}`);

class MemoryStorage {
  constructor() {
    this.values = new Map();
  }

  getItem(key) {
    return this.values.has(key) ? this.values.get(key) : null;
  }

  setItem(key, value) {
    this.values.set(key, String(value));
  }
}

const snapshot = (localeId, message) => ({
  formatVersion: '1.0.0',
  localeId,
  messages: {
    'workspace.gdevelop_publish': message,
    'workspace.gdevelop_storage.allocation.locked':
      localeId === 'en-US'
        ? 'Another project operation is in progress. Request ID: {requestId}'
        : '另一个工程操作仍在处理中。请求 ID：{requestId}',
    'unrelated.message': 'must be filtered',
  },
});

{
  const requests = [];
  const storage = new MemoryStorage();
  const session = new localization.PlaymeshLocalizationSession({
    bootstrap: snapshot('zh-CN', '发布'),
    storage,
    fetchImpl: async url => {
      requests.push(url);
      const locale = new URL(url, 'http://localhost').searchParams.get(
        'locale'
      );
      return {
        ok: true,
        json: async () =>
          locale === 'en-US'
            ? snapshot('en-US', 'Publish')
            : snapshot('zh-CN', '发布（已刷新）'),
      };
    },
  });

  const firstScreen = session.getState();
  assert.equal(firstScreen.ready, true);
  assert.equal(firstScreen.entryAuthoritative, true);
  assert.equal(firstScreen.language, 'zh_CN');
  assert.equal(firstScreen.localeId, 'zh-CN');
  assert.equal(firstScreen.messages['workspace.gdevelop_publish'], '发布');
  assert.equal('unrelated.message' in firstScreen.messages, false);

  let notificationCount = 0;
  const unsubscribe = session.subscribe(() => notificationCount++);
  session.activate();
  await session.initialize();
  assert.equal(requests[0], '/dev/api/localization?locale=zh-CN');
  assert.equal(
    session.translate('workspace.gdevelop_publish'),
    '发布（已刷新）'
  );
  assert.equal(
    session.translate('workspace.gdevelop_storage.allocation.locked', {
      requestId: 'dev-zh',
    }),
    '另一个工程操作仍在处理中。请求 ID：dev-zh'
  );
  assert.equal(
    session.translate('workspace.gdevelop_missing_key'),
    'workspace.gdevelop_missing_key'
  );

  await session.useGDevelopLanguage('en_US');
  const switched = session.getState();
  assert.equal(requests[1], '/dev/api/localization?locale=en-US');
  assert.equal(switched.language, 'en_US');
  assert.equal(switched.targetLanguage, 'en_US');
  assert.equal(switched.localeId, 'en-US');
  assert.equal(session.getPromptLocale(), 'en-US');
  assert.equal(session.translate('workspace.gdevelop_publish'), 'Publish');
  assert.equal(
    session.translate('workspace.gdevelop_storage.allocation.locked', {
      requestId: 'dev-en',
    }),
    'Another project operation is in progress. Request ID: dev-en'
  );
  assert.ok(notificationCount >= 4);
  unsubscribe();

  let offlineRequestCount = 0;
  const offlineSession = new localization.PlaymeshLocalizationSession({
    storage,
    fetchImpl: async () => {
      offlineRequestCount++;
      throw new Error('offline');
    },
  });
  await offlineSession.useGDevelopLanguage('en_US');
  const offlineState = offlineSession.getState();
  assert.equal(offlineRequestCount, 1);
  assert.equal(offlineState.stale, true);
  assert.equal(offlineState.language, 'en_US');
  assert.equal(offlineState.localeId, 'en-US');
  assert.equal(
    offlineSession.translate('workspace.gdevelop_publish'),
    'Publish'
  );
}

const messageKeysSource = await readFile(
  path.join(overlayDirectory, 'PlaymeshMessageKeys.js'),
  'utf8'
);
const registeredMessageKeys = [
  ...messageKeysSource.matchAll(
    /\b[A-Za-z][A-Za-z0-9]*:\s*["']([^"']+)["']/g
  ),
].map(match => match[1]);
assert.ok(registeredMessageKeys.length > 0);
assert.ok(
  registeredMessageKeys.every(key => key.startsWith('workspace.gdevelop_')),
  'every WebIDE message key must stay inside the runtime localization prefix'
);
assert.match(
  messageKeysSource,
  /homeUnofficialNotice:\s*["']workspace\.gdevelop_home\.unofficial_notice["']/
);
assert.match(
  messageKeysSource,
  /homeNoticesTitle:\s*["']workspace\.gdevelop_home\.notices_title["']/
);
assert.match(
  messageKeysSource,
  /storageAllocationLocked:\s*["']workspace\.gdevelop_storage\.allocation\.locked["']/
);
const expectedAiMessageMappings = {
  aiPlanTitle: 'workspace.gdevelop_ai.plan.title',
  aiPlanPending: 'workspace.gdevelop_ai.plan.pending',
  aiPlanInProgress: 'workspace.gdevelop_ai.plan.in_progress',
  aiPlanCompleted: 'workspace.gdevelop_ai.plan.completed',
  aiApprovalGrantsTitle: 'workspace.gdevelop_ai.approval_grants.title',
  aiApprovalGrantsEmpty: 'workspace.gdevelop_ai.approval_grants.empty',
  aiApprovalGrantRevoke: 'workspace.gdevelop_ai.approval_grants.revoke',
  aiApprovalGrantsRefresh: 'workspace.gdevelop_ai.approval_grants.refresh',
  aiApprovalGrantsLoadFailed:
    'workspace.gdevelop_ai.approval_grants.load_failed',
  aiApprovalGrantRevokeFailed:
    'workspace.gdevelop_ai.approval_grants.revoke_failed',
  aiApprovalModeTitle: 'workspace.gdevelop_ai.approval_mode.title',
  aiApprovalModeRequest: 'workspace.gdevelop_ai.approval_mode.request',
  aiApprovalModeAlways: 'workspace.gdevelop_ai.approval_mode.always',
  aiApprovalModeSaving: 'workspace.gdevelop_ai.approval_mode.saving',
  aiApprovalModeSaveFailed:
    'workspace.gdevelop_ai.approval_mode.save_failed',
  aiApprovalModeUncertain: 'workspace.gdevelop_ai.approval_mode.uncertain',
  aiApprovalModeRetry: 'workspace.gdevelop_ai.approval_mode.retry',
  aiEventPayloadRequired: 'workspace.gdevelop_ai.event_payload.required',
  aiEventPayloadInvalid: 'workspace.gdevelop_ai.event_payload.invalid',
  aiSessionClipboardError: 'workspace.gdevelop_ai.session.clipboard_error',
  aiSessionDiagnostic: 'workspace.gdevelop_ai.session.diagnostic',
  aiSessionDiagnosticLocal: 'workspace.gdevelop_ai.session.diagnostic_local',
};
const expectedProjectConfigMessageMappings = {
  projectConfigTitle: 'workspace.gdevelop_project_config.title',
  projectConfigScope: 'workspace.gdevelop_project_config.scope',
  projectConfigGameType: 'workspace.gdevelop_project_config.game_type',
  projectConfigSingle: 'workspace.gdevelop_project_config.single',
  projectConfigOnline: 'workspace.gdevelop_project_config.online',
  projectConfigLoading: 'workspace.gdevelop_project_config.loading',
  projectConfigSaving: 'workspace.gdevelop_project_config.saving',
  projectConfigMissingNotSaved:
    'workspace.gdevelop_project_config.missing_not_saved',
  projectConfigInvalid: 'workspace.gdevelop_project_config.invalid',
  projectConfigUnavailable: 'workspace.gdevelop_project_config.unavailable',
  projectConfigRetry: 'workspace.gdevelop_project_config.retry',
  projectConfigConflict: 'workspace.gdevelop_project_config.conflict',
  projectConfigSaveFailed: 'workspace.gdevelop_project_config.save_failed',
  projectConfigPublishBlocked:
    'workspace.gdevelop_project_config.publish_blocked',
  projectConfigScanUnknownWarning:
    'workspace.gdevelop_project_config.scan_unknown_warning',
};
for (const [name, key] of Object.entries({
  ...expectedAiMessageMappings,
  ...expectedProjectConfigMessageMappings,
})) {
  assert.match(
    messageKeysSource,
    new RegExp(`${name}:\\s*['\"]${key.replaceAll('.', '\\.')}['\"]`),
    `${name} must stay bound to ${key}`
  );
}

const localeDirectory = path.resolve(
  testDirectory,
  '../../../../../playmesh-localization/locales'
);
const [zhMessages, enMessages] = await Promise.all([
  readFile(path.join(localeDirectory, 'zh-CN/app.json'), 'utf8').then(JSON.parse),
  readFile(path.join(localeDirectory, 'en-US/app.json'), 'utf8').then(JSON.parse),
]);
assert.equal(
  zhMessages['workspace.gdevelop_ai.approval_mode.always'],
  '始终允许'
);
assert.equal(
  enMessages['workspace.gdevelop_ai.approval_mode.always'],
  'Always allow'
);
for (const messages of [zhMessages, enMessages]) {
  assert.equal(
    messages['workspace.gdevelop_ai.approval_mode.request_description'],
    undefined
  );
  assert.equal(
    messages['workspace.gdevelop_ai.approval_mode.always_description'],
    undefined
  );
  assert.equal(
    messages['workspace.gdevelop_ai.approval_mode.grants_unaffected'],
    undefined
  );
  assert.equal(
    messages['workspace.gdevelop_ai.approval_grants.description'],
    undefined
  );
}

{
  let requestCount = 0;
  const standaloneSession = new localization.PlaymeshLocalizationSession({
    storage: new MemoryStorage(),
    fetchImpl: async () => {
      requestCount++;
      throw new Error('offline');
    },
  });
  standaloneSession.activate();
  await Promise.resolve();
  assert.equal(standaloneSession.getState().entryAuthoritative, false);
  assert.equal(standaloneSession.getState().language, 'en');
  assert.equal(requestCount, 0);
}

const sourcePolicy = await readFile(
  path.resolve(testDirectory, '../scripts/apply-source-policy.mjs'),
  'utf8'
);
assert.match(
  sourcePolicy,
  /activatePlaymeshLocalizationSession\(\);[\s\S]*?cleanupPlaymeshLegacyBrowserPersistence\(\);[\s\S]*?Window\.setUpContextMenu\(\);/
);
assert.match(sourcePolicy, /preferences\.language = playmeshEntryLanguage/);
assert.match(
  sourcePolicy,
  /playmeshLocalizationSession\.prepareGDevelopLanguage\(language\)/
);
assert.match(
  sourcePolicy,
  /playmeshLocalizationSession\.commitPreparedGDevelopLanguage\(/
);
assert.match(sourcePolicy, /<PlaymeshLocalizationSessionProvider>/);

process.stdout.write('GDevelop Playmesh localization session tests passed.\n');
