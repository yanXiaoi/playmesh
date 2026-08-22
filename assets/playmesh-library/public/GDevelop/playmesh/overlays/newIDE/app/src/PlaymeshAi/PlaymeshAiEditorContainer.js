// @flow

import * as React from 'react';
import { type I18n as I18nType } from '@lingui/core';
import { I18n } from '@lingui/react';
import Snackbar from '@material-ui/core/Snackbar';
import { type HotReloadSteps } from '../EmbeddedGame/EmbeddedGameFrame';
import {
  type RenderEditorContainerPropsWithRef,
  type EditorContainerExtraProps,
} from '../MainFrame/EditorContainers/BaseEditor';
import {
  type SceneEventsOutsideEditorChanges,
  type InstancesOutsideEditorChanges,
  type ObjectsOutsideEditorChanges,
  type ObjectGroupsOutsideEditorChanges,
  type ProjectItemRenamedOutsideEditorChanges,
  type WillDeleteSceneChanges,
  type WillDeleteObjectChanges,
} from '../EditorFunctions/OutsideEditorChanges';
import UnsavedChangesContext from '../MainFrame/UnsavedChangesContext';
import { type ObjectWithContext } from '../ObjectsList/EnumerateObjects';
import { type ResourceSearchAndInstallOptions } from '../EditorFunctions';
import { type ResourceManagementProps } from '../ResourcesList/ResourceSource';
import { type FileMetadata } from '../ProjectsStorage';
import { type EventsFunctionsExtensionsState } from '../EventsFunctionsExtensionsLoader/EventsFunctionsExtensionsContext';
import { useEnsureExtensionInstalled } from '../AiGeneration/UseEnsureExtensionInstalled';
import {
  playmeshAiClient,
  type PlaymeshAiApprovalGrant,
  type PlaymeshAiToolsEnvelope,
} from './PlaymeshAiClient';
import {
  completePlaymeshAiFailureDiagnostics,
  createPlaymeshAiLocalRequestId,
  isPlaymeshAiConnectionFailure,
  reportPlaymeshAiFailure,
  type PlaymeshAiFailureDiagnostic,
} from './PlaymeshAiDiagnostics';
import {
  PlaymeshAiSessionController,
  playmeshAiSessionController,
  type PlaymeshAiSessionState,
} from './PlaymeshAiSessionController';
import {
  PlaymeshAiExecutionAbortRegistry,
  PlaymeshAiExecutor,
  playmeshAiExecutionAbortRegistry,
} from './PlaymeshAiExecutor';
import { PlaymeshAiCallCoordinator } from './PlaymeshAiCallCoordinator';
import {
  PlaymeshAiAgentRunLoop,
  selectPlaymeshAiRunLoopAction,
} from './PlaymeshAiAgentRunLoop';
import { applyPlaymeshAiEventPayload } from './PlaymeshAiEventPayloadExecutor';
import {
  buildPlaymeshAiEnqueueRequests,
  createPlaymeshAiClientId,
  isPlaymeshAiTerminalCall,
  parsePlaymeshManualToolCalls,
  type PlaymeshAiApprovalMode,
  type PlaymeshAiCall,
  type PlaymeshAiObject,
  type PlaymeshAiSession,
} from './PlaymeshAiProtocol';
import { getPlaymeshAiSelectedSceneName } from './PlaymeshAiSelectedScene';
import { readPlaymeshInstalledExtensionDocs } from './PlaymeshAiInstalledDocumentation';
import {
  PlaymeshAiPanel,
  type PlaymeshAiAgentBaseUrlsStatus,
  type PlaymeshAiApprovalModeStatus,
  type PlaymeshAiChatActionFeedback,
  type PlaymeshAiSessionFeedback,
  type PlaymeshAiSessionOperation,
} from './PlaymeshAiPanel';
import { getIsPlaymeshAiEnabled } from './PlaymeshAiFeatureFlags';
import {
  buildPlaymeshAiApprovalPresentations,
  filterPlaymeshAiApprovals,
  type PlaymeshAiApproval,
} from './PlaymeshAiApprovalPolicy';
import { type PlaymeshAiPlan } from './PlaymeshAiLocalToolWrappers';
import {
  copyPlaymeshText,
  readPlaymeshText,
} from './PlaymeshAiClipboard';
import { serializePlaymeshAiReturnStatus } from './PlaymeshAiReturnStatus';
import { type PlaymeshAiRunnerOptions } from './PlaymeshAiEditorFunctionTypes';
import {
  PlaymeshAiPromptTemplateController,
  type PlaymeshAiPromptTemplateState,
} from './PlaymeshAiPromptTemplateController';
import { usePlaymeshLocalization } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';

const CONTEXT_REFRESH_DELAY_MS = 500;
const FEATURE_POLICY_POLL_INTERVAL_MS = 500;
// One authoritative editor session owns context/calls/approvals. Chat and
// Agent are prompt views of this session; Agent remains the internal channel
// so external Agent calls retain the existing root-Token approval semantics.
const PLAYMESH_AI_SESSION_CHANNEL_MODE = 'agent';
const VALID_GAME_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const noop = () => {};
const EVENT_PAYLOAD_VALIDATION_CODES = new Set([
  'event_payload_not_allowed',
  'event_payload_schema_invalid',
  'event_payload_scene_mismatch',
]);

type PlaymeshAiMode = 'chat' | 'agent';
type PlaymeshAiView = PlaymeshAiMode;
type PlaymeshAiApprovalDecision = 'once' | 'project' | 'always' | 'reject';
type PlaymeshAiEventPayloadValidation =
  | 'none'
  | 'required'
  | 'invalid';
type PlaymeshAiConnectionStatus = 'online' | 'offline';
type PlaymeshAiChatOperation = {|
  echo: number,
  turnId: ?string,
|};
type PlaymeshAiApprovalGrantsStatus =
  | 'idle'
  | 'loading'
  | 'ready'
  | 'load_failed'
  | 'revoke_failed';
type PlaymeshAiTransientNotice = {|
  key: number,
  kind:
    | 'prompt_chat'
    | 'prompt_agent'
    | 'return_status_copied'
    | 'execution_submitted'
    | 'execution_succeeded',
|};
type PlaymeshAiReadySessionState = {|
  session: PlaymeshAiSession,
  tools: PlaymeshAiToolsEnvelope,
  mode: PlaymeshAiMode,
  gameId: string,
  sessionEpoch: number,
|};
type Props = {|
  isActive: boolean,
  project: ?gdProject,
  fileMetadata: ?FileMetadata,
  setToolbar: (?React.Node) => void,
  extraEditorProps: ?EditorContainerExtraProps,
  resourceManagementProps: ResourceManagementProps,
  eventsFunctionsExtensionsState: EventsFunctionsExtensionsState,
  onPreviewOrRefresh: () => Promise<void>,
  onOpenLayout: (
    sceneName: string,
    options?: {|
      openEventsEditor: boolean,
      openSceneEditor: boolean,
      focusWhenOpened:
        | 'scene-or-events-otherwise'
        | 'scene'
        | 'events'
        | 'none',
    |}
  ) => void,
  onSceneEventsModifiedOutsideEditor: (
    changes: SceneEventsOutsideEditorChanges
  ) => void,
  onInstancesModifiedOutsideEditor: (
    changes: InstancesOutsideEditorChanges
  ) => void,
  onObjectsModifiedOutsideEditor: (
    changes: ObjectsOutsideEditorChanges
  ) => void,
  onObjectGroupsModifiedOutsideEditor: (
    changes: ObjectGroupsOutsideEditorChanges
  ) => void,
  onProjectItemRenamedOutsideEditor: (
    changes: ProjectItemRenamedOutsideEditorChanges
  ) => void,
  onWillDeleteScene: (changes: WillDeleteSceneChanges) => Promise<void>,
  onWillDeleteObject: (changes: WillDeleteObjectChanges) => void,
  onWillInstallExtension: (extensionNames: Array<string>) => void,
  onExtensionInstalled: (extensionNames: Array<string>) => void,
  onCloseAskAi: () => void,
  i18n: I18nType,
|};

const hasAuthoritativeProjectIdentity = (
  project: ?gdProject,
  fileMetadata: ?FileMetadata
): boolean => {
  const gameId = fileMetadata && fileMetadata.gameId;
  const fileIdentifier = fileMetadata && fileMetadata.fileIdentifier;
  return !!(
    project &&
    typeof gameId === 'string' &&
    VALID_GAME_ID.test(gameId) &&
    typeof fileIdentifier === 'string' &&
    fileIdentifier &&
    project.getPackageName() === gameId
  );
};

const sessionFeedbackForError = (
  error: any
): PlaymeshAiSessionFeedback => {
  const code = error && typeof error.code === 'string' ? error.code : '';
  const status = error && Number.isFinite(error.status) ? error.status : null;
  if (
    code === 'project_identity_missing' ||
    code === 'project_identity_mismatch'
  ) {
    return 'missing_game_id';
  }
  if (status === 401) return 'unauthorized';
  if (status === 404) return 'not_found';
  if (status === 409) return 'conflict';
  if (
    code === 'ai_unavailable' ||
    code === 'ai_request_timeout' ||
    code === 'ai_network_error'
  ) {
    return 'network_error';
  }
  if (code === 'clipboard_unavailable') return 'clipboard_error';
  if (
    code === 'ai_session_open_local_failed' ||
    code === 'ai_client_unhandled_error' ||
    code === 'ai_coordinator_start_failed'
  ) {
    return 'local_error';
  }
  return 'generic_error';
};

const requireReadySessionState = (
  state: PlaymeshAiSessionState
): PlaymeshAiReadySessionState => {
  if (!state.session || !state.tools || !state.mode || !state.gameId) {
    throw new Error('The local GDevelop AI session is incomplete.');
  }
  return {
    session: state.session,
    tools: state.tools,
    mode: state.mode,
    gameId: state.gameId,
    sessionEpoch: state.sessionEpoch,
  };
};

export type PlaymeshAiEditorInterface = {|
  getProject: () => void,
  updateToolbar: () => void,
  forceUpdateEditor: () => void,
  onEventsBasedObjectChildrenEdited: (
    eventsBasedObject: gdEventsBasedObject,
    options?: {| editedObject?: ?gdObject, hasResourceChanged?: boolean |}
  ) => void,
  onSceneObjectEdited: (
    scene: gdLayout,
    objectWithContext: ObjectWithContext,
    hasResourceChanged?: boolean
  ) => void,
  onSceneObjectsDeleted: (scene: gdLayout) => void,
  onSceneEventsModifiedOutsideEditor: (
    changes: SceneEventsOutsideEditorChanges
  ) => void,
  onInstancesModifiedOutsideEditor: (
    changes: InstancesOutsideEditorChanges
  ) => void,
  onObjectsModifiedOutsideEditor: (
    changes: ObjectsOutsideEditorChanges
  ) => void,
  onObjectGroupsModifiedOutsideEditor: (
    changes: ObjectGroupsOutsideEditorChanges
  ) => void,
  onWillDeleteObject: (changes: WillDeleteObjectChanges) => void,
  selectAllInsideEditor: () => void,
  startOrOpenChat: (?{| aiRequestId: string | null |}) => void,
  notifyChangesToInGameEditor: (hotReloadSteps: HotReloadSteps) => void,
  switchInGameEditorIfNoHotReloadIsNeeded: () => void,
  prepareToReposition: () => void,
  suspendOnDrawerClose: () => void,
  requestClose: () => Promise<boolean>,
|};

const mergeCall = (
  calls: Array<PlaymeshAiCall>,
  nextCall: PlaymeshAiCall
): Array<PlaymeshAiCall> => {
  const index = calls.findIndex(call => call.callId === nextCall.callId);
  if (index < 0) return [...calls, nextCall];
  const next = [...calls];
  next[index] = nextCall;
  return next;
};

const hasActiveCall = (calls: $ReadOnlyArray<PlaymeshAiCall>): boolean =>
  calls.some(call => call.state === 'running');

const projectIdentity = (fileMetadata: ?FileMetadata): string =>
  fileMetadata
    ? `${fileMetadata.gameId || ''}:${fileMetadata.fileIdentifier || ''}`
    : '';

const PlaymeshAiEditor: React.ComponentType<{
  ...Props,
  +ref?: React.RefSetter<PlaymeshAiEditorInterface>,
}> = React.forwardRef<
  Props,
  PlaymeshAiEditorInterface
>((props, ref) => {
    const { setToolbar } = props;
    const { localeId, t } = usePlaymeshLocalization();
    const { triggerUnsavedChanges } = React.useContext(
      UnsavedChangesContext
    );
    const { ensureExtensionInstalled } = useEnsureExtensionInstalled({
      project: props.project,
      i18n: props.i18n,
    });
    const [mode, setMode] = React.useState<PlaymeshAiMode>('chat');
    const [view, setView] = React.useState<PlaymeshAiView>('chat');
    const [sessionState, setSessionState] = React.useState<?PlaymeshAiReadySessionState>(() => {
      const sharedState = playmeshAiSessionController.getState();
      try {
        return requireReadySessionState(sharedState);
      } catch (_) {
        return null;
      }
    });
    const [calls, setCalls] = React.useState<Array<PlaymeshAiCall>>([]);
    const [approvals, setApprovals] = React.useState<
      Array<PlaymeshAiApproval>
    >([]);
    const [approvalGrants, setApprovalGrants] = React.useState<
      Array<PlaymeshAiApprovalGrant>
    >([]);
    const [
      approvalGrantsStatus,
      setApprovalGrantsStatus,
    ] = React.useState<PlaymeshAiApprovalGrantsStatus>('idle');
    const [approvalModeStatus, setApprovalModeStatus] = React.useState<PlaymeshAiApprovalModeStatus>(
      'idle'
    );
    const [manualInput, setManualInput] = React.useState('');
    const [chatOperation, setChatOperation] = React.useState<?PlaymeshAiChatOperation>(
      null
    );
    const [busy, setBusy] = React.useState(false);
    const [featureEnabled, setFeatureEnabled] = React.useState(
      getIsPlaymeshAiEnabled()
    );
    const [sessionOperation, setSessionOperation] = React.useState<PlaymeshAiSessionOperation>(
      'idle'
    );
    const [sessionFeedback, setSessionFeedback] = React.useState<PlaymeshAiSessionFeedback>(
      'none'
    );
    const [sessionFailure, setSessionFailure] = React.useState<?PlaymeshAiFailureDiagnostic>(
      null
    );
    const [transientNotice, setTransientNotice] = React.useState<?PlaymeshAiTransientNotice>(
      null
    );
    const transientNoticeKeyRef = React.useRef(0);
    const [returnStatusCopyFeedback, setReturnStatusCopyFeedback] = React.useState<
      'none' | 'copy_failed'
    >('none');
    const [chatActionFeedback, setChatActionFeedback] = React.useState<PlaymeshAiChatActionFeedback>(
      'none'
    );
    const [agentBaseUrls, setAgentBaseUrls] = React.useState<Array<string>>([]);
    const [agentBaseUrl, setAgentBaseUrl] = React.useState('');
    const [agentBaseUrlsStatus, setAgentBaseUrlsStatus] = React.useState<PlaymeshAiAgentBaseUrlsStatus>(
      'idle'
    );
    const [
      eventPayloadValidation,
      setEventPayloadValidation,
    ] = React.useState<PlaymeshAiEventPayloadValidation>('none');
    const [connectionStatus, setConnectionStatus] = React.useState<PlaymeshAiConnectionStatus>(
      'online'
    );
    const [plan, setPlan] = React.useState<?PlaymeshAiPlan>(null);
    const promptTemplateControllerRef = React.useRef<PlaymeshAiPromptTemplateController>(
      new PlaymeshAiPromptTemplateController({ client: playmeshAiClient })
    );
    const [promptTemplateState, setPromptTemplateState] = React.useState<PlaymeshAiPromptTemplateState>(
      promptTemplateControllerRef.current.getState()
    );

    const mountedRef = React.useRef<boolean>(true);
    const showTransientNotice = React.useCallback(
      (kind: PlaymeshAiTransientNotice['kind']) => {
        if (!mountedRef.current) return;
        transientNoticeKeyRef.current += 1;
        setTransientNotice({ key: transientNoticeKeyRef.current, kind });
      },
      []
    );
    const recordSessionFailure = React.useCallback(
      (operation: string, error: mixed): PlaymeshAiFailureDiagnostic => {
        const diagnostic = reportPlaymeshAiFailure(operation, error);
        if (mountedRef.current) {
          setSessionFailure(diagnostic);
          if (isPlaymeshAiConnectionFailure(error)) {
            setConnectionStatus('offline');
          }
        }
        return diagnostic;
      },
      []
    );
    const pausedRef = React.useRef<boolean>(false);
    const contextDirtyRef = React.useRef<boolean>(false);
    const refreshTimerRef = React.useRef<?TimeoutID>(null);
    const sessionStateRef = React.useRef<?PlaymeshAiReadySessionState>(
      sessionState
    );
    const callsRef = React.useRef<Array<PlaymeshAiCall>>(calls);
    const projectRef = React.useRef<?gdProject>(props.project);
    const fileMetadataRef = React.useRef<?FileMetadata>(props.fileMetadata);
    const runnerOptionsRef = React.useRef<?PlaymeshAiRunnerOptions>(null);
    const coordinatorRef = React.useRef<?PlaymeshAiCallCoordinator>(null);
    const activityAbortRef = React.useRef<?AbortController>(null);
    const agentBaseUrlsAbortRef = React.useRef<?AbortController>(null);
    const agentBaseUrlsGenerationRef = React.useRef(0);
    const approvalModeOperationRef = React.useRef(false);
    const approvalModeOperationGenerationRef = React.useRef(0);
    const agentBaseUrlRef = React.useRef(agentBaseUrl);
    const sessionOperationRef = React.useRef<PlaymeshAiSessionOperation>(
      'idle'
    );
    const lastFeaturePolicyRef = React.useRef<?boolean>(null);
    const autoOpenAttemptedIdentityRef = React.useRef('');
    const chatInputGenerationRef = React.useRef(0);
    const manualExecutionCallIdsRef = React.useRef<Set<string>>(new Set());
    const lastManualEchoRef = React.useRef(0);
    const pasteRunCopyCallIdsRef = React.useRef<?Set<string>>(null);
    const [pasteRunCopyGeneration, setPasteRunCopyGeneration] = React.useState(
      0
    );
    const executionAbortRegistryRef = React.useRef<PlaymeshAiExecutionAbortRegistry>(
      playmeshAiExecutionAbortRegistry
    );
    const runLoopStepRef = React.useRef<() => Promise<boolean>>(() =>
      Promise.resolve(false)
    );
    const pumpRef = React.useRef<() => Promise<void>>(() => Promise.resolve());

    sessionStateRef.current = sessionState;
    callsRef.current = calls;
    projectRef.current = props.project;
    fileMetadataRef.current = props.fileMetadata;
    agentBaseUrlRef.current = agentBaseUrl;

    const sessionControllerRef = React.useRef<PlaymeshAiSessionController>(
      playmeshAiSessionController
    );
    React.useEffect(() => {
      const trackedIds = manualExecutionCallIdsRef.current;
      if (!trackedIds.size) return;
      const trackedCalls = calls.filter(call => trackedIds.has(call.callId));
      if (
        trackedCalls.length !== trackedIds.size ||
        trackedCalls.some(call => !isPlaymeshAiTerminalCall(call))
      ) {
        return;
      }
      manualExecutionCallIdsRef.current = new Set();
      if (trackedCalls.every(call => call.state === 'finished')) {
        setChatActionFeedback('none');
        setSessionFailure(null);
        showTransientNotice('execution_succeeded');
      } else {
        setChatActionFeedback('execution_failed');
      }
    }, [calls, showTransientNotice]);
    const executorRef = React.useRef<PlaymeshAiExecutor>(
      new PlaymeshAiExecutor({
        applyEventPayload: applyPlaymeshAiEventPayload,
        updatePlan: async (nextPlan: PlaymeshAiPlan) => setPlan(nextPlan),
        readFullDocs: async ({
          project,
          extensionNames,
        }: {|
          project: gdProject,
          extensionNames: string,
        |}) =>
          readPlaymeshInstalledExtensionDocs({ project, extensionNames }),
        onProjectModified: triggerUnsavedChanges,
        onFetchNewlyAddedResources:
          props.resourceManagementProps.onFetchNewlyAddedResources,
        onNewResourcesAdded:
          props.resourceManagementProps.onNewResourcesAdded,
        eventsFunctionsExtensionsState: props.eventsFunctionsExtensionsState,
        onPreviewOrRefresh: props.onPreviewOrRefresh,
      })
    );
    executorRef.current.onFetchNewlyAddedResources =
      props.resourceManagementProps.onFetchNewlyAddedResources;
    executorRef.current.onNewResourcesAdded =
      props.resourceManagementProps.onNewResourcesAdded;
    executorRef.current.eventsFunctionsExtensionsState =
      props.eventsFunctionsExtensionsState;
    executorRef.current.onPreviewOrRefresh = props.onPreviewOrRefresh;
    const runLoopRef = React.useRef<PlaymeshAiAgentRunLoop>(
      new PlaymeshAiAgentRunLoop({
        step: () => runLoopStepRef.current(),
        onError: error => {
          recordSessionFailure('gdevelop.ai.run_loop', error);
        },
      })
    );

    runnerOptionsRef.current = {
      i18n: props.i18n,
      editorCallbacks: {
        onOpenLayout: props.onOpenLayout,
        onCreateProject: async () => ({
          exampleSlug: null,
          createdProject: null,
        }),
      },
      toolOptions: null,
      relatedAiRequestId: null,
      getRelatedAiRequestLastMessages: () => ({
        lastUserMessage: null,
        lastAssistantMessages: [],
      }),
      generateEvents: async () => ({
        generationCompleted: false,
        errorMessage: 'The official AI generation service is disabled.',
      }),
      onSceneEventsModifiedOutsideEditor:
        props.onSceneEventsModifiedOutsideEditor,
      onInstancesModifiedOutsideEditor:
        props.onInstancesModifiedOutsideEditor,
      onObjectsModifiedOutsideEditor: props.onObjectsModifiedOutsideEditor,
      onObjectGroupsModifiedOutsideEditor:
        props.onObjectGroupsModifiedOutsideEditor,
      onProjectItemRenamedOutsideEditor:
        props.onProjectItemRenamedOutsideEditor,
      onWillDeleteScene: props.onWillDeleteScene,
      onWillDeleteObject: props.onWillDeleteObject,
      ensureExtensionInstalled,
      onWillInstallExtension: props.onWillInstallExtension,
      onExtensionInstalled: props.onExtensionInstalled,
      getAssetStoreTagForNewObject: () => null,
      searchAndInstallAsset: async () => ({
        status: 'nothing-found',
        message: 'The asset store is disabled.',
        createdObjects: [],
        assetShortHeader: null,
        isTheFirstOfItsTypeInProject: false,
      }),
      searchAndInstallResources: async ({
        resources,
      }: ResourceSearchAndInstallOptions) => ({
        results: resources.map(resource => ({
          resourceName: resource.resourceName,
          resourceKind: resource.resourceKind,
          status: 'nothing-found',
        })),
      }),
    };

    const replaceCalls = React.useCallback((nextCalls: Array<PlaymeshAiCall>) => {
      const current = sessionStateRef.current;
      if (current) {
        executionAbortRegistryRef.current.reconcileCalls(
          current.gameId,
          current.session.editorSessionId,
          nextCalls
        );
      }
      callsRef.current = nextCalls;
      if (mountedRef.current) setCalls(nextCalls);
    }, []);

    const upsertCall = React.useCallback(
      (nextCall: PlaymeshAiCall) =>
        replaceCalls(mergeCall(callsRef.current, nextCall)),
      [replaceCalls]
    );

    const refreshApprovals = React.useCallback(async () => {
      const current = sessionStateRef.current;
      if (!current) return;
      try {
        const allApprovals = await playmeshAiClient.listApprovals(
          activityAbortRef.current
            ? activityAbortRef.current.signal
            : undefined
        );
        if (!mountedRef.current) return;
        setApprovals(
          filterPlaymeshAiApprovals({
            approvals: allApprovals,
            gameId: current.gameId,
            editorSessionId: current.session.editorSessionId,
            mode: current.mode,
          })
        );
      } catch (error) {
        recordSessionFailure('ai_approvals.list', error);
      }
    }, [recordSessionFailure]);

    const refreshApprovalGrants = React.useCallback(async () => {
      const fileMetadata = fileMetadataRef.current;
      const gameId = fileMetadata && fileMetadata.gameId;
      if (!gameId) {
        if (mountedRef.current) {
          setApprovalGrants([]);
          setApprovalGrantsStatus('idle');
        }
        return;
      }
      if (mountedRef.current) setApprovalGrantsStatus('loading');
      try {
        const grants = await playmeshAiClient.listApprovalGrants(
          activityAbortRef.current
            ? activityAbortRef.current.signal
            : undefined
        );
        if (
          !mountedRef.current ||
          !fileMetadataRef.current ||
          fileMetadataRef.current.gameId !== gameId
        ) {
          return;
        }
        setApprovalGrants(
          grants.filter(
            grant =>
              grant.scopeKind === 'gdevelop' &&
              grant.scopeId === gameId &&
              (!grant.gameId || grant.gameId === gameId)
          )
        );
        setApprovalGrantsStatus('ready');
      } catch (error) {
        recordSessionFailure('ai_approval_grants.list', error);
        if (mountedRef.current) setApprovalGrantsStatus('load_failed');
      }
    }, [recordSessionFailure]);

    const revokeApprovalGrant = React.useCallback(
      async (grantId: string) => {
        setApprovalGrantsStatus('loading');
        try {
          await playmeshAiClient.revokeApprovalGrant(
            grantId,
            activityAbortRef.current
              ? activityAbortRef.current.signal
              : undefined
          );
          await refreshApprovalGrants();
        } catch (error) {
          recordSessionFailure('ai_approval_grants.revoke', error);
          if (mountedRef.current) {
            setApprovalGrantsStatus('revoke_failed');
          }
        }
      },
      [recordSessionFailure, refreshApprovalGrants]
    );

    const changeApprovalMode = React.useCallback(
      async (approvalMode: PlaymeshAiApprovalMode): Promise<void> => {
        if (!sessionStateRef.current || approvalModeOperationRef.current) return;
        const operationGeneration =
          ++approvalModeOperationGenerationRef.current;
        approvalModeOperationRef.current = true;
        if (mountedRef.current) setApprovalModeStatus('saving');
        try {
          await sessionControllerRef.current.updateApprovalMode(
            approvalMode,
            activityAbortRef.current
              ? activityAbortRef.current.signal
              : undefined
          );
          if (
            operationGeneration !== approvalModeOperationGenerationRef.current
          ) {
            return;
          }
          await refreshApprovals();
          if (
            mountedRef.current &&
            operationGeneration === approvalModeOperationGenerationRef.current
          ) {
            setApprovalModeStatus('idle');
          }
        } catch (error) {
          if (
            !mountedRef.current ||
            operationGeneration !== approvalModeOperationGenerationRef.current ||
            (error &&
              (error.code === 'approval_mode_operation_stale' ||
                error.code === 'approval_mode_operation_aborted'))
          ) {
            return;
          }
          recordSessionFailure('gdevelop.ai.approval_mode.update', error);
          setApprovalModeStatus(
            error && error.code === 'approval_mode_update_not_applied'
              ? 'save_failed'
              : 'uncertain'
          );
        } finally {
          if (
            operationGeneration === approvalModeOperationGenerationRef.current
          ) {
            approvalModeOperationRef.current = false;
          }
        }
      },
      [recordSessionFailure, refreshApprovals]
    );

    const retryApprovalMode = React.useCallback(async (): Promise<void> => {
      if (!sessionStateRef.current || approvalModeOperationRef.current) return;
      const operationGeneration = ++approvalModeOperationGenerationRef.current;
      approvalModeOperationRef.current = true;
      if (mountedRef.current) setApprovalModeStatus('saving');
      try {
        await sessionControllerRef.current.reconcileApprovalMode(
          activityAbortRef.current ? activityAbortRef.current.signal : undefined
        );
        if (
          operationGeneration !== approvalModeOperationGenerationRef.current
        ) {
          return;
        }
        await refreshApprovals();
        if (
          mountedRef.current &&
          operationGeneration === approvalModeOperationGenerationRef.current
        ) {
          setApprovalModeStatus('idle');
        }
      } catch (error) {
        if (
          !mountedRef.current ||
          operationGeneration !== approvalModeOperationGenerationRef.current ||
          (error &&
            (error.code === 'approval_mode_operation_stale' ||
              error.code === 'approval_mode_operation_aborted'))
        ) {
          return;
        }
        recordSessionFailure('gdevelop.ai.approval_mode.reconcile', error);
        setApprovalModeStatus('uncertain');
      } finally {
        if (
          operationGeneration === approvalModeOperationGenerationRef.current
        ) {
          approvalModeOperationRef.current = false;
        }
      }
    }, [recordSessionFailure, refreshApprovals]);

    const retryPromptTemplates = React.useCallback(
      async () => {
        await promptTemplateControllerRef.current.load(localeId);
      },
      [localeId]
    );

    const loadAgentBaseUrls = React.useCallback(async () => {
      const generation = ++agentBaseUrlsGenerationRef.current;
      if (agentBaseUrlsAbortRef.current) {
        agentBaseUrlsAbortRef.current.abort();
      }
      const controller = new AbortController();
      agentBaseUrlsAbortRef.current = controller;
      setAgentBaseUrlsStatus('loading');
      try {
        const baseUrls = await playmeshAiClient.listAgentBaseUrls(
          controller.signal
        );
        if (
          !mountedRef.current ||
          controller.signal.aborted ||
          generation !== agentBaseUrlsGenerationRef.current
        ) {
          return;
        }
        const previous = agentBaseUrlRef.current;
        const currentOrigin = global.location ? global.location.origin : '';
        const selected = baseUrls.includes(previous)
          ? previous
          : baseUrls.find(baseUrl => new URL(baseUrl).origin === currentOrigin) ||
            baseUrls[0];
        if (!selected) {
          throw new Error('No Agent connection address is available.');
        }
        setAgentBaseUrls(baseUrls);
        setAgentBaseUrl(selected);
        setAgentBaseUrlsStatus('ready');
      } catch (error) {
        if (
          controller.signal.aborted ||
          generation !== agentBaseUrlsGenerationRef.current
        ) {
          return;
        }
        reportPlaymeshAiFailure('gdevelop.ai.agent_base_urls', error);
        if (mountedRef.current) {
          setAgentBaseUrls([]);
          setAgentBaseUrl('');
          setAgentBaseUrlsStatus('load_failed');
        }
      } finally {
        if (agentBaseUrlsAbortRef.current === controller) {
          agentBaseUrlsAbortRef.current = null;
        }
      }
    }, []);

    React.useEffect(() => {
      if (view === 'agent' && agentBaseUrlsStatus === 'idle') {
        void loadAgentBaseUrls();
      }
    }, [agentBaseUrlsStatus, loadAgentBaseUrls, view]);

    const changeAgentBaseUrl = React.useCallback(
      (nextBaseUrl: string) => {
        if (agentBaseUrls.includes(nextBaseUrl)) {
          setAgentBaseUrl(nextBaseUrl);
        }
      },
      [agentBaseUrls]
    );

    const changeView = React.useCallback((nextView: PlaymeshAiView) => {
      chatInputGenerationRef.current++;
      setView(nextView);
      if (nextView === 'chat' || nextView === 'agent') setMode(nextView);
      setSessionFeedback('none');
      setReturnStatusCopyFeedback('none');
      setChatActionFeedback('none');
      promptTemplateControllerRef.current.selectMode(nextView);
    }, []);

    const updatePromptTemplateContent = React.useCallback(
      (content: string) =>
        promptTemplateControllerRef.current.updateContent(content),
      []
    );

    const savePromptTemplate = React.useCallback(
      async () => {
        await promptTemplateControllerRef.current.save();
      },
      []
    );

    const resetPromptTemplate = React.useCallback(async () => {
      if (!global.confirm(t(playmeshMessages.aiPromptTemplatesResetConfirm))) {
        return;
      }
      await promptTemplateControllerRef.current.reset();
    }, [t]);

    const stopCoordinator = React.useCallback(() => {
      runLoopRef.current.stop();
      if (coordinatorRef.current) coordinatorRef.current.stop();
      coordinatorRef.current = null;
    }, []);

    const startCoordinator = React.useCallback(
      async (state: PlaymeshAiReadySessionState) => {
        stopCoordinator();
        runLoopRef.current.resume();
        const coordinator = new PlaymeshAiCallCoordinator({
          client: {
            listCalls: (gameId, sessionId, afterSequence, signal) =>
              playmeshAiClient.listCalls(
                gameId,
                sessionId,
                afterSequence,
                signal
              ),
          },
          gameId: state.gameId,
          sessionId: state.session.editorSessionId,
          onCallsChanged: (nextCalls: Array<PlaymeshAiCall>) => {
            replaceCalls(nextCalls);
            void refreshApprovals();
            void pumpRef.current();
          },
          onError: error => {
            recordSessionFailure('gdevelop.ai.call.list', error);
          },
        });
        coordinatorRef.current = coordinator;
        await coordinator.start();
        if (mountedRef.current) setConnectionStatus('online');
        await refreshApprovals();
      },
      [
        recordSessionFailure,
        refreshApprovals,
        replaceCalls,
        stopCoordinator,
      ]
    );

    React.useEffect(
      () =>
        sessionControllerRef.current.subscribe(nextState => {
          let ready = null;
          try {
            ready = requireReadySessionState(nextState);
          } catch (_) {
            // A lifecycle close/switch is represented by an empty controller
            // state; the panel simply detaches until the next project session.
          }
          const previous = sessionStateRef.current;
          sessionStateRef.current = ready;
          if (mountedRef.current) setSessionState(ready);
          if (!ready) {
            approvalModeOperationGenerationRef.current++;
            approvalModeOperationRef.current = false;
            if (mountedRef.current) setApprovalModeStatus('idle');
            stopCoordinator();
            return;
          }
          const sessionChanged = !!(
            !previous ||
            previous.session.editorSessionId !== ready.session.editorSessionId
          );
          if (previous && sessionChanged) {
            approvalModeOperationGenerationRef.current++;
            approvalModeOperationRef.current = false;
            manualExecutionCallIdsRef.current = new Set();
            lastManualEchoRef.current = 0;
            setChatOperation(null);
            setApprovalModeStatus('idle');
            replaceCalls([]);
          }
          if (sessionChanged || !coordinatorRef.current) {
            void startCoordinator(ready).then(() => pumpRef.current());
          }
        }),
      [replaceCalls, startCoordinator, stopCoordinator]
    );

    const selectedSceneName = React.useCallback(
      (): ?string => getPlaymeshAiSelectedSceneName(),
      []
    );

    const refreshSession = React.useCallback(async () => {
      const current = sessionStateRef.current;
      const project = projectRef.current;
      const fileMetadata = fileMetadataRef.current;
      if (
        !current ||
        !project ||
        !fileMetadata ||
        hasActiveCall(callsRef.current)
      ) {
        contextDirtyRef.current = true;
        return;
      }
      contextDirtyRef.current = false;
      const signal = activityAbortRef.current
        ? activityAbortRef.current.signal
        : undefined;
      try {
        const refreshed = requireReadySessionState(
          await sessionControllerRef.current.refresh({
            project,
            fileMetadata,
            locale: localeId,
            selectedSceneName: selectedSceneName(),
            signal,
          })
        );
        const previousSessionId = current.session.editorSessionId;
        sessionStateRef.current = refreshed;
        if (mountedRef.current) setSessionState(refreshed);
        if (refreshed.session.editorSessionId !== previousSessionId) {
          manualExecutionCallIdsRef.current = new Set();
          lastManualEchoRef.current = 0;
          setChatOperation(null);
          setApprovalModeStatus('idle');
          replaceCalls([]);
          if (!pausedRef.current) await startCoordinator(refreshed);
        }
        if (mountedRef.current) setConnectionStatus('online');
      } catch (error) {
        if (signal && signal.aborted) return;
        if (!mountedRef.current) return;
        recordSessionFailure('gdevelop.ai.session.refresh', error);
      }
    }, [
      localeId,
      recordSessionFailure,
      replaceCalls,
      selectedSceneName,
      startCoordinator,
    ]);

    const scheduleContextRefresh = React.useCallback(() => {
      contextDirtyRef.current = true;
      if (refreshTimerRef.current !== null) {
        global.clearTimeout(refreshTimerRef.current);
      }
      refreshTimerRef.current = global.setTimeout(() => {
        refreshTimerRef.current = null;
        void refreshSession();
      }, CONTEXT_REFRESH_DELAY_MS);
    }, [refreshSession]);

    runLoopStepRef.current = async () => {
      if (pausedRef.current) return false;
      const current = sessionStateRef.current;
      const project = projectRef.current;
      const fileMetadata = fileMetadataRef.current;
      const signal = activityAbortRef.current
        ? activityAbortRef.current.signal
        : undefined;
      const runnerOptions = runnerOptionsRef.current;
      if (
        !current ||
        !project ||
        !fileMetadata ||
        !runnerOptions ||
        (signal && signal.aborted)
      ) {
        return false;
      }
      const action = selectPlaymeshAiRunLoopAction(callsRef.current);
      if (action.type === 'wait') return false;
      if (action.type === 'blocked_multiple_active') {
        throw new Error('Multiple active GDevelop AI calls were observed.');
      }
      let runnable = action.type === 'execute' ? action.call : null;
      if (action.type === 'lease') {
        const leased = await executorRef.current.leaseNext({
          gameId: current.gameId,
          sessionId: current.session.editorSessionId,
          signal,
        });
        if (!leased) return false;
        upsertCall(leased);
        if (leased.state !== 'running') return false;
        runnable = leased;
      }
      if (!runnable) return false;
      const call = runnable;
      const abortHandle = executionAbortRegistryRef.current.begin(
        current.gameId,
        call,
        signal
      );
      const result = await executorRef.current
        .executeCall({
          gameId: current.gameId,
          sessionId: current.session.editorSessionId,
          sessionEpoch: current.sessionEpoch,
          isSessionEpochCurrent: epoch =>
            sessionControllerRef.current.isSessionEpochCurrent(epoch),
          call,
          project,
          selectedSceneName: selectedSceneName(),
          fileMetadata,
          toolsContract: current.tools,
          runnerOptions,
          signal,
          abortHandle,
        })
        .finally(() =>
          executionAbortRegistryRef.current.finish(
            current.gameId,
            current.session.editorSessionId,
            call.callId,
            abortHandle
          )
        );
      if (result.call) upsertCall(result.call);
      if (coordinatorRef.current) await coordinatorRef.current.pollNow();
      await refreshApprovals();
      if (contextDirtyRef.current && !hasActiveCall(callsRef.current)) {
        scheduleContextRefresh();
      }
      return ['finished', 'failed'].includes(result.status);
    };
    pumpRef.current = () => runLoopRef.current.pump();

    const openSession = React.useCallback(
      async () => {
        const project = props.project;
        const fileMetadata = props.fileMetadata;
        if (sessionOperationRef.current !== 'idle') return;
        if (
          !featureEnabled ||
          !project ||
          !fileMetadata ||
          !hasAuthoritativeProjectIdentity(project, fileMetadata)
        ) {
          setSessionFeedback('missing_game_id');
          return;
        }
        sessionOperationRef.current = 'opening';
        setSessionOperation('opening');
        setSessionFeedback('none');
        setSessionFailure(null);
        setBusy(true);
        setEventPayloadValidation('none');
        executionAbortRegistryRef.current.abortAll();
        if (activityAbortRef.current) activityAbortRef.current.abort();
        const activityAbort = new AbortController();
        activityAbortRef.current = activityAbort;
        const requestedIdentity = projectIdentity(fileMetadata);
        try {
          const opened = requireReadySessionState(
            await sessionControllerRef.current.open({
              mode: PLAYMESH_AI_SESSION_CHANNEL_MODE,
              project,
              fileMetadata,
              locale: localeId,
              selectedSceneName: selectedSceneName(),
              signal: activityAbort.signal,
            })
          );
          if (
            activityAbort.signal.aborted ||
            projectIdentity(fileMetadataRef.current) !== requestedIdentity
          ) {
            sessionControllerRef.current.abandon();
            if (mountedRef.current && !activityAbort.signal.aborted) {
              setSessionFeedback('missing_game_id');
            }
            return;
          }
          sessionStateRef.current = opened;
          if (!mountedRef.current) return;
          setSessionState(opened);
          manualExecutionCallIdsRef.current = new Set();
          lastManualEchoRef.current = 0;
          setChatOperation(null);
          setApprovalModeStatus('idle');
          replaceCalls([]);
          setPlan(null);
          setConnectionStatus('online');
          setSessionFeedback('none');
          setSessionFailure(null);
          pausedRef.current = false;
          try {
            await startCoordinator(opened);
          } catch (error) {
            // The editor session is already authoritative at this point. A
            // background coordinator failure must not relabel a successful
            // session POST as `session.open` or discard the usable session.
            const coordinatorFailure = completePlaymeshAiFailureDiagnostics(
              error,
              {
                code: 'ai_coordinator_start_failed',
                operation: 'gdevelop.ai.coordinator.start',
                requestId: createPlaymeshAiLocalRequestId(),
              }
            );
            recordSessionFailure(
              'gdevelop.ai.coordinator.start',
              coordinatorFailure
            );
            if (mountedRef.current) setConnectionStatus('offline');
          }
          void pumpRef.current();
        } catch (error) {
          if (activityAbort.signal.aborted) {
            return;
          }
          if (!mountedRef.current) return;
          recordSessionFailure('gdevelop.ai.session.open', error);
          setSessionFeedback(sessionFeedbackForError(error));
        } finally {
          if (activityAbortRef.current === activityAbort) {
            sessionOperationRef.current = 'idle';
            if (mountedRef.current) {
              setSessionOperation('idle');
              setBusy(false);
            }
          }
        }
      }, [
        featureEnabled,
        localeId,
        props.fileMetadata,
        props.project,
        recordSessionFailure,
        replaceCalls,
        selectedSceneName,
        startCoordinator,
      ]
    );

    React.useEffect(
      () => {
        const identity = projectIdentity(props.fileMetadata);
        if (
          !featureEnabled ||
          !identity ||
          !hasAuthoritativeProjectIdentity(props.project, props.fileMetadata) ||
          sessionStateRef.current ||
          sessionOperationRef.current !== 'idle' ||
          autoOpenAttemptedIdentityRef.current === identity
        ) {
          return;
        }
        autoOpenAttemptedIdentityRef.current = identity;
        void openSession();
      },
      [featureEnabled, openSession, props.fileMetadata, props.project]
    );

    const retrySession = React.useCallback(() => {
      const identity = projectIdentity(fileMetadataRef.current);
      if (
        !identity ||
        !hasAuthoritativeProjectIdentity(
          projectRef.current,
          fileMetadataRef.current
        )
      ) {
        setSessionFeedback('missing_game_id');
        return;
      }
      autoOpenAttemptedIdentityRef.current = '';
      void openSession();
    }, [openSession]);

    const copyPrompt = React.useCallback(async () => {
      let current = sessionStateRef.current;
      if (!current || sessionOperationRef.current !== 'idle') return;
      if (
        mode === 'agent' &&
        (agentBaseUrlsStatus !== 'ready' || !agentBaseUrl)
      ) {
        return;
      }
      sessionOperationRef.current = 'copying_prompt';
      setSessionOperation('copying_prompt');
      setSessionFeedback('none');
      setSessionFailure(null);
      setBusy(true);
      const signal = activityAbortRef.current
        ? activityAbortRef.current.signal
        : undefined;
      try {
        const selectedBeforeCopy = selectedSceneName();
        const projectContext = current.session.projectContext;
        if (
          contextDirtyRef.current ||
          !projectContext ||
          projectContext.selectedSceneName !== selectedBeforeCopy
        ) {
          await refreshSession();
          current = sessionStateRef.current;
          const refreshedContext =
            current && current.session.projectContext
              ? current.session.projectContext
              : null;
          if (
            !current ||
            !refreshedContext ||
            refreshedContext.selectedSceneName !== selectedSceneName()
          ) {
            const error = new Error(
              'The GDevelop AI scene index could not be refreshed.'
            );
            (error /*: any */).code = 'project_context_refresh_required';
            (error /*: any */).stage = 'pre_request';
            (error /*: any */).operation = 'gdevelop.ai.session.prompt.copy';
            throw error;
          }
        }
        const promptSession = current;
        if (!promptSession) {
          const error = new Error(
            'The GDevelop AI editor session is no longer available.'
          );
          (error /*: any */).code = 'gdevelop_ai_session_not_found';
          (error /*: any */).stage = 'pre_request';
          (error /*: any */).operation = 'gdevelop.ai.session.prompt.copy';
          throw error;
        }
        await playmeshAiClient.copyPromptToClipboard({
          gameId: promptSession.gameId,
          sessionId: promptSession.session.editorSessionId,
          mode,
          agentBaseUrl: mode === 'agent' ? agentBaseUrl : null,
          signal,
        });
        if (mountedRef.current) {
          setConnectionStatus('online');
          setSessionFailure(null);
          showTransientNotice(
            mode === 'agent' ? 'prompt_agent' : 'prompt_chat'
          );
        }
      } catch (error) {
        if (mountedRef.current) {
          recordSessionFailure('gdevelop.ai.session.prompt.copy', error);
          setSessionFeedback(sessionFeedbackForError(error));
        }
      } finally {
        sessionOperationRef.current = 'idle';
        if (mountedRef.current) {
          setSessionOperation('idle');
          setBusy(false);
        }
      }
    }, [
      agentBaseUrl,
      agentBaseUrlsStatus,
      mode,
      recordSessionFailure,
      refreshSession,
      selectedSceneName,
      showTransientNotice,
    ]);

    const copyReturnStatus = React.useCallback(
      async (statusText: string) => {
        setReturnStatusCopyFeedback('none');
        setChatActionFeedback('none');
        try {
          if (!(await copyPlaymeshText({ value: statusText }))) {
            const error = new Error(
              'The browser blocked copying the GDevelop AI return status.'
            );
            (error /*: any */).code = 'clipboard_unavailable';
            (error /*: any */).stage = 'local_ui';
            (error /*: any */).operation = 'gdevelop.ai.return_status.copy';
            throw error;
          }
          if (mountedRef.current) {
            showTransientNotice('return_status_copied');
          }
        } catch (error) {
          if (!mountedRef.current) return;
          recordSessionFailure('gdevelop.ai.return_status.copy', error);
          setReturnStatusCopyFeedback('copy_failed');
        }
      },
      [recordSessionFailure, showTransientNotice]
    );

    const executeManualInput = React.useCallback(async (
      inputText: string
    ): Promise<?Array<string>> => {
      const current = sessionStateRef.current;
      if (!current || !inputText.trim() || busy) return null;
      setSessionFailure(null);
      setSessionFeedback('none');
      setEventPayloadValidation('none');
      setBusy(true);
      setReturnStatusCopyFeedback('none');
      setChatActionFeedback('none');
      const signal = activityAbortRef.current
        ? activityAbortRef.current.signal
        : undefined;
      let parsedEcho /*: ?number */ = null;
      try {
        const parsed = parsePlaymeshManualToolCalls(
          inputText,
          current.tools.tools,
          lastManualEchoRef.current
        );
        parsedEcho = parsed.echo;
        lastManualEchoRef.current = parsed.echo;
        setChatOperation({ echo: parsed.echo, turnId: null });
        const turn = await playmeshAiClient.createTurn(
          current.gameId,
          current.session.editorSessionId,
          createPlaymeshAiClientId('message'),
          parsed.echo,
          signal
        );
        if (mountedRef.current) {
          setChatOperation({
            echo: turn.echo == null ? parsed.echo : turn.echo,
            turnId: turn.turnId,
          });
        }
        const requests = buildPlaymeshAiEnqueueRequests({
          calls: parsed.calls,
          turnId: turn.turnId,
          session: current.session,
          tools: current.tools.tools,
        });
        manualExecutionCallIdsRef.current = new Set(
          requests.map(request => request.callId)
        );
        for (const request of requests) {
          upsertCall(
            await playmeshAiClient.enqueueCall(
              current.gameId,
              current.session.editorSessionId,
              request,
              signal
            )
          );
        }
        setEventPayloadValidation('none');
        showTransientNotice('execution_submitted');
        if (coordinatorRef.current) await coordinatorRef.current.pollNow();
        await refreshApprovals();
        void pumpRef.current();
        return requests.map(request => request.callId);
      } catch (error) {
        if (!mountedRef.current) return [];
        manualExecutionCallIdsRef.current = new Set();
        const failureEcho =
          parsedEcho != null
            ? parsedEcho
            : error && Number.isSafeInteger(error.echo) && error.echo > 0
            ? Number(error.echo)
            : null;
        if (failureEcho != null) {
          if (failureEcho > lastManualEchoRef.current) {
            lastManualEchoRef.current = failureEcho;
          }
          setChatOperation({ echo: failureEcho, turnId: null });
        }
        recordSessionFailure(
          'gdevelop.ai.turn.execute',
          error
        );
        if (error.code === 'event_payload_required') {
          setEventPayloadValidation('required');
        } else if (EVENT_PAYLOAD_VALIDATION_CODES.has(error.code)) {
          setEventPayloadValidation('invalid');
        } else setEventPayloadValidation('none');
        return [];
      } finally {
        if (mountedRef.current) setBusy(false);
      }
    }, [
      busy,
      recordSessionFailure,
      refreshApprovals,
      showTransientNotice,
      upsertCall,
    ]);

    const executeManual = React.useCallback(
      async (): Promise<void> => {
        await executeManualInput(manualInput);
      },
      [executeManualInput, manualInput]
    );

    const pasteAndExecute = React.useCallback(async () => {
      if (busy) return;
      const inputGeneration = ++chatInputGenerationRef.current;
      // Clear first so a denied clipboard read can never submit stale text.
      setManualInput('');
      setReturnStatusCopyFeedback('none');
      setChatActionFeedback('reading_clipboard');
      const result = await readPlaymeshText({
        fallbackRead: () =>
          playmeshAiClient.readAppClipboardText(
            activityAbortRef.current
              ? activityAbortRef.current.signal
              : undefined
          ),
      });
      if (!mountedRef.current) return;
      // Clear, typing, or another paste while permission UI was open wins.
      if (chatInputGenerationRef.current !== inputGeneration) return;
      if (!result.ok) {
        const error = completePlaymeshAiFailureDiagnostics(
          new Error('The browser denied clipboard read access.'),
          {
            code: 'clipboard_read_unavailable',
            operation: 'gdevelop.ai.chat.clipboard.read',
            requestId: createPlaymeshAiLocalRequestId(),
          }
        );
        recordSessionFailure('gdevelop.ai.chat.clipboard.read', error);
        setChatActionFeedback('clipboard_read_failed');
        return;
      }
      if (!result.value.trim()) {
        setChatActionFeedback('clipboard_empty');
        return;
      }
      setManualInput(result.value);
      setChatActionFeedback('none');
      const callIds = await executeManualInput(result.value);
      if (!mountedRef.current || callIds === null) return;
      pasteRunCopyCallIdsRef.current = new Set(callIds);
      setPasteRunCopyGeneration(generation => generation + 1);
    }, [busy, executeManualInput, recordSessionFailure]);

    const clearManualInput = React.useCallback(() => {
      chatInputGenerationRef.current++;
      setManualInput('');
      setChatActionFeedback('none');
    }, []);

    const changeManualInput = React.useCallback((value: string) => {
      chatInputGenerationRef.current++;
      setManualInput(value);
      setChatActionFeedback('none');
    }, []);

    const cancelCall = React.useCallback(async (callId: string) => {
      const current = sessionStateRef.current;
      if (!current) return;
      if (
        !executionAbortRegistryRef.current.abortCall(
          current.gameId,
          current.session.editorSessionId,
          callId
        )
      ) {
        return;
      }
      try {
        upsertCall(
          await playmeshAiClient.cancelCall(
            current.gameId,
            current.session.editorSessionId,
            callId,
            activityAbortRef.current
              ? activityAbortRef.current.signal
              : undefined
          )
        );
      } catch (error) {
        recordSessionFailure('gdevelop.ai.call.cancel', error);
      }
    }, [recordSessionFailure, upsertCall]);

    const cancelTurn = React.useCallback(
      async (turnId: string) => {
        const current = sessionStateRef.current;
        if (
          !current ||
          executionAbortRegistryRef.current.hasNonCancellableExecutionForTurn(
            current.gameId,
            current.session.editorSessionId,
            turnId
          )
        ) {
          return;
        }
        executionAbortRegistryRef.current.abortTurn(
          current.gameId,
          current.session.editorSessionId,
          turnId
        );
        try {
          await playmeshAiClient.cancelTurn(
            current.gameId,
            current.session.editorSessionId,
            turnId,
            activityAbortRef.current
              ? activityAbortRef.current.signal
              : undefined
          );
          if (coordinatorRef.current) await coordinatorRef.current.pollNow();
          await refreshApprovals();
        } catch (error) {
          recordSessionFailure('gdevelop.ai.turn.cancel', error);
        }
      },
      [recordSessionFailure, refreshApprovals]
    );

    const decideApproval = React.useCallback(
      async (
        approvalId: string,
        decision: PlaymeshAiApprovalDecision
      ) => {
        const current = sessionStateRef.current;
        if (!current) return;
        try {
          await playmeshAiClient.decideApproval(
            approvalId,
            decision,
            activityAbortRef.current
              ? activityAbortRef.current.signal
              : undefined
          );
          await refreshApprovals();
          if (decision === 'always') await refreshApprovalGrants();
          if (coordinatorRef.current) await coordinatorRef.current.pollNow();
          void pumpRef.current();
        } catch (error) {
          recordSessionFailure('ai_approvals.decide', error);
        }
      },
      [recordSessionFailure, refreshApprovalGrants, refreshApprovals]
    );

    const updateToolbar = React.useCallback(() => {
      setToolbar(null);
    }, [setToolbar]);

    React.useEffect(updateToolbar, [updateToolbar]);

    const dismissAiSurface = React.useCallback(
      async (
        closeEditor: boolean,
        _blockOnCloseFailure: boolean = false
      ): Promise<boolean> => {
        const current = sessionStateRef.current;
        if (current) {
          executionAbortRegistryRef.current.abortSession(
            current.gameId,
            current.session.editorSessionId
          );
        } else {
          executionAbortRegistryRef.current.abortAll();
        }
        if (activityAbortRef.current) activityAbortRef.current.abort();
        activityAbortRef.current = null;
        if (mountedRef.current) {
          setBusy(true);
        }
        stopCoordinator();
        // Panel, page and project changes only detach the UI. All project
        // sessions remain owned by the Developer Gateway until Developer Mode
        // is turned off and the Gateway disposes them together.
        sessionControllerRef.current.abandon();
        sessionStateRef.current = null;
        manualExecutionCallIdsRef.current = new Set();
        lastManualEchoRef.current = 0;
        approvalModeOperationGenerationRef.current++;
        approvalModeOperationRef.current = false;
        replaceCalls([]);
        if (mountedRef.current) {
          setSessionState(null);
          setChatOperation(null);
          setApprovalModeStatus('idle');
          setApprovals([]);
          setPlan(null);
          setApprovalGrants([]);
          setApprovalGrantsStatus('idle');
          setSessionOperation('idle');
          setSessionFeedback('none');
          setBusy(false);
        }
        if (closeEditor) props.onCloseAskAi();
        return true;
      },
      [
        props.onCloseAskAi,
        replaceCalls,
        stopCoordinator,
      ]
    );

    const lastIdentityRef = React.useRef(projectIdentity(props.fileMetadata));
    React.useEffect(
      () => {
        const nextIdentity = projectIdentity(props.fileMetadata);
        if (lastIdentityRef.current && nextIdentity !== lastIdentityRef.current) {
          void dismissAiSurface(true);
        } else if (
          !lastIdentityRef.current &&
          nextIdentity &&
          hasAuthoritativeProjectIdentity(props.project, props.fileMetadata)
        ) {
          // 创建项目后立刻重新读取权威上下文，开放 session 入口。
          setSessionFeedback('none');
        }
        lastIdentityRef.current = nextIdentity;
      },
      [dismissAiSurface, props.fileMetadata, props.project]
    );

    React.useEffect(
      () => {
        if (sessionStateRef.current) scheduleContextRefresh();
      },
      [props.project, scheduleContextRefresh]
    );

    React.useEffect(
      () => {
        const updateFeaturePolicy = () => {
          const enabled = getIsPlaymeshAiEnabled();
          if (mountedRef.current) setFeatureEnabled(enabled);
          if (!enabled && lastFeaturePolicyRef.current !== false) {
            void dismissAiSurface(true);
          }
          lastFeaturePolicyRef.current = enabled;
        };
        updateFeaturePolicy();
        const interval = global.setInterval(
          updateFeaturePolicy,
          FEATURE_POLICY_POLL_INTERVAL_MS
        );
        return () => global.clearInterval(interval);
      },
      [dismissAiSurface]
    );

    React.useEffect(
      () => {
        void refreshApprovalGrants();
      },
      [props.fileMetadata, refreshApprovalGrants]
    );

    React.useEffect(
      () =>
        promptTemplateControllerRef.current.subscribe(setPromptTemplateState),
      []
    );

    React.useEffect(
      () => {
        void promptTemplateControllerRef.current.load(localeId);
      },
      [localeId]
    );

    React.useEffect(
      () => {
        if (
          promptTemplateState.selectedMode !== view &&
          !['loading', 'saving', 'resetting'].includes(
            promptTemplateState.status
          )
        ) {
          promptTemplateControllerRef.current.selectMode(view);
        }
      },
      [view, promptTemplateState.selectedMode, promptTemplateState.status]
    );

    React.useEffect(
      () => {
        if (sessionStateRef.current) scheduleContextRefresh();
      },
      [localeId, scheduleContextRefresh]
    );

    React.useEffect(
      () => {
        // Drawer/tab visibility is a UI attachment detail. Once mounted, the
        // WebIDE worker keeps processing Agent and Chat calls in background.
        pausedRef.current = false;
        if (sessionStateRef.current && !coordinatorRef.current) {
          void startCoordinator(sessionStateRef.current).then(() =>
            pumpRef.current()
          );
        }
      },
      [props.isActive, startCoordinator]
    );

    React.useEffect(() => () => {
      mountedRef.current = false;
      if (agentBaseUrlsAbortRef.current) {
        agentBaseUrlsAbortRef.current.abort();
      }
      agentBaseUrlsAbortRef.current = null;
      if (refreshTimerRef.current !== null) {
        global.clearTimeout(refreshTimerRef.current);
      }
      stopCoordinator();
      promptTemplateControllerRef.current.dispose();
    }, [stopCoordinator]);

    const markContextDirty = React.useCallback(() => {
      scheduleContextRefresh();
    }, [scheduleContextRefresh]);

    const requestClose = React.useCallback(
      (): Promise<boolean> => {
        const current = sessionStateRef.current;
        if (
          executionAbortRegistryRef.current.hasNonCancellableExecution(
            current && current.gameId,
            current && current.session.editorSessionId
          )
        ) {
          return Promise.resolve(false);
        }
        // Closing the panel only detaches its UI. The WebIDE/project lifecycle
        // host owns the remote session and the editor lease closes it.
        return Promise.resolve(true);
      },
      []
    );

    React.useImperativeHandle(ref, () => ({
      getProject: noop,
      updateToolbar,
      forceUpdateEditor: markContextDirty,
      onEventsBasedObjectChildrenEdited: (
        _eventsBasedObject: gdEventsBasedObject,
        _options?: {| editedObject?: ?gdObject, hasResourceChanged?: boolean |}
      ) => markContextDirty(),
      onSceneObjectEdited: (
        _scene: gdLayout,
        _objectWithContext: ObjectWithContext,
        _hasResourceChanged?: boolean
      ) => markContextDirty(),
      onSceneObjectsDeleted: (_scene: gdLayout) => markContextDirty(),
      onSceneEventsModifiedOutsideEditor: (
        _changes: SceneEventsOutsideEditorChanges
      ) => markContextDirty(),
      onInstancesModifiedOutsideEditor: (
        _changes: InstancesOutsideEditorChanges
      ) => markContextDirty(),
      onObjectsModifiedOutsideEditor: (
        _changes: ObjectsOutsideEditorChanges
      ) => markContextDirty(),
      onObjectGroupsModifiedOutsideEditor: (
        _changes: ObjectGroupsOutsideEditorChanges
      ) => markContextDirty(),
      onWillDeleteObject: (_changes: WillDeleteObjectChanges) =>
        markContextDirty(),
      selectAllInsideEditor: noop,
      startOrOpenChat: (_options: ?{| aiRequestId: string | null |}) => {
        setView('chat');
        setMode('chat');
        promptTemplateControllerRef.current.selectMode('chat');
        if (!sessionStateRef.current) void openSession();
      },
      notifyChangesToInGameEditor: (_hotReloadSteps: HotReloadSteps) =>
        markContextDirty(),
      switchInGameEditorIfNoHotReloadIsNeeded: noop,
      prepareToReposition: () => {
        stopCoordinator();
      },
      suspendOnDrawerClose: () => {
        pausedRef.current = false;
      },
      requestClose,
    }));

    const approvalPresentations = buildPlaymeshAiApprovalPresentations({
      approvals,
      calls,
      tools: sessionState ? sessionState.tools.tools : [],
    });
    const returnStatusText = serializePlaymeshAiReturnStatus({
      mode,
      session: sessionState && sessionState.session,
      chatOperation,
      calls,
      approvals: approvalPresentations,
      failure: sessionFailure,
      connectionStatus,
    });

    React.useEffect(
      () => {
        const pendingCallIds = pasteRunCopyCallIdsRef.current;
        if (pendingCallIds === null) return;
        const activeCallIds: Set<string> = pendingCallIds || new Set();
        if (busy) return;
        if (activeCallIds.size) {
          const pendingCalls = calls.filter(call =>
            activeCallIds.has(call.callId)
          );
          if (
            pendingCalls.length !== activeCallIds.size ||
            pendingCalls.some(call => !isPlaymeshAiTerminalCall(call))
          ) {
            return;
          }
        }
        pasteRunCopyCallIdsRef.current = null;
        // Copy the exact serializer output for this render. Successful,
        // failed, rejected and cancelled calls all use the same status path;
        // a pre-request failure reaches this branch with an empty id set.
        void copyReturnStatus(returnStatusText);
      },
      [
        busy,
        calls,
        copyReturnStatus,
        pasteRunCopyGeneration,
        returnStatusText,
      ]
    );

    return (
      <>
        <PlaymeshAiPanel
          view={view}
          onViewChanged={changeView}
          session={sessionState && sessionState.session}
          calls={calls}
          approvals={approvalPresentations}
          approvalGrants={approvalGrants}
          approvalGrantsStatus={approvalGrantsStatus}
          approvalMode={
            sessionState
              ? sessionState.session.approvalMode
              : 'request_approval'
          }
          approvalModeStatus={approvalModeStatus}
          plan={plan}
          manualInput={manualInput}
          onManualInputChanged={changeManualInput}
          busy={busy}
          canOpenSession={
            featureEnabled &&
            hasAuthoritativeProjectIdentity(props.project, props.fileMetadata)
          }
          sessionOperation={sessionOperation}
          sessionFeedback={sessionFeedback}
          sessionFailure={sessionFailure}
          eventPayloadValidation={eventPayloadValidation}
          connectionStatus={connectionStatus}
          promptTemplateState={promptTemplateState}
          returnStatusText={returnStatusText}
          returnStatusCopyFeedback={returnStatusCopyFeedback}
          chatActionFeedback={chatActionFeedback}
          agentBaseUrls={agentBaseUrls}
          agentBaseUrl={agentBaseUrl}
          agentBaseUrlsStatus={agentBaseUrlsStatus}
          onRetrySession={retrySession}
          onCopyPrompt={copyPrompt}
          onCopyReturnStatus={copyReturnStatus}
          onExecuteManual={executeManual}
          onPasteAndExecute={pasteAndExecute}
          onClearManualInput={clearManualInput}
          onAgentBaseUrlChanged={changeAgentBaseUrl}
          onRetryAgentBaseUrls={loadAgentBaseUrls}
          isCallCancellationDisabled={callId => {
            const current = sessionStateRef.current;
            return current
              ? executionAbortRegistryRef.current.hasNonCancellableExecutionForCall(
                  current.gameId,
                  current.session.editorSessionId,
                  callId
                )
              : true;
          }}
          isTurnCancellationDisabled={turnId => {
            const current = sessionStateRef.current;
            return current
              ? executionAbortRegistryRef.current.hasNonCancellableExecutionForTurn(
                  current.gameId,
                  current.session.editorSessionId,
                  turnId
                )
              : true;
          }}
          onCancelCall={cancelCall}
          onCancelTurn={cancelTurn}
          onApproveOnce={approvalId => decideApproval(approvalId, 'once')}
          onApproveProject={approvalId =>
            decideApproval(approvalId, 'project')
          }
          onApproveAlways={approvalId =>
            decideApproval(approvalId, 'always')
          }
          onReject={approvalId => decideApproval(approvalId, 'reject')}
          onRefreshApprovalGrants={refreshApprovalGrants}
          onRevokeApprovalGrant={revokeApprovalGrant}
          onApprovalModeChanged={changeApprovalMode}
          onRetryApprovalMode={retryApprovalMode}
          onPromptTemplateContentChanged={updatePromptTemplateContent}
          onRetryPromptTemplates={retryPromptTemplates}
          onSavePromptTemplate={savePromptTemplate}
          onResetPromptTemplate={resetPromptTemplate}
        />
        <Snackbar
          key={transientNotice ? transientNotice.key : 'closed'}
          open={!!transientNotice}
          autoHideDuration={3000}
          anchorOrigin={{ vertical: 'bottom', horizontal: 'center' }}
          onClose={() => setTransientNotice(null)}
          ContentProps={{
            'aria-describedby': 'playmesh-ai-transient-notice',
          }}
          message={
            <span
              id="playmesh-ai-transient-notice"
              role="status"
              aria-live="polite"
            >
              {transientNotice && transientNotice.kind === 'prompt_agent'
                ? t(playmeshMessages.aiPromptCopiedAgent)
                : transientNotice && transientNotice.kind === 'prompt_chat'
                ? t(playmeshMessages.aiPromptCopiedChat)
                : transientNotice &&
                  transientNotice.kind === 'return_status_copied'
                ? t(playmeshMessages.aiReturnStatusCopied)
                : transientNotice &&
                  transientNotice.kind === 'execution_succeeded'
                ? t(playmeshMessages.aiExecutionSucceeded)
                : t(playmeshMessages.aiExecutionSubmitted)}
            </span>
          }
        />
      </>
    );
  }
);

export const renderPlaymeshAiEditorContainer = (
  props: RenderEditorContainerPropsWithRef
): React.Node => {
  const {
    ref,
    isActive,
    project,
    fileMetadata,
    setToolbar,
    extraEditorProps,
    resourceManagementProps,
    onOpenLayout,
    onCloseAskAi,
  } = props;
  return (
    <I18n>
      {({ i18n }) => (
        <PlaymeshAiEditor
          ref={ref}
          i18n={i18n}
          isActive={isActive}
          project={project}
          fileMetadata={fileMetadata}
          setToolbar={setToolbar}
          extraEditorProps={extraEditorProps}
          resourceManagementProps={resourceManagementProps}
          eventsFunctionsExtensionsState={
            props.eventsFunctionsExtensionsState
          }
          onPreviewOrRefresh={props.onPreviewOrRefresh}
          onOpenLayout={onOpenLayout}
          onSceneEventsModifiedOutsideEditor={
            props.onSceneEventsModifiedOutsideEditor
          }
          onInstancesModifiedOutsideEditor={
            props.onInstancesModifiedOutsideEditor
          }
          onObjectsModifiedOutsideEditor={props.onObjectsModifiedOutsideEditor}
          onObjectGroupsModifiedOutsideEditor={
            props.onObjectGroupsModifiedOutsideEditor
          }
          onProjectItemRenamedOutsideEditor={
            props.onProjectItemRenamedOutsideEditor
          }
          onWillDeleteScene={props.onWillDeleteScene}
          onWillDeleteObject={props.onWillDeleteObject}
          onWillInstallExtension={props.onWillInstallExtension}
          onExtensionInstalled={props.onExtensionInstalled}
          onCloseAskAi={onCloseAskAi}
        />
      )}
    </I18n>
  );
};

export default PlaymeshAiEditor;
