// @flow

import * as React from 'react';
import Paper from '../UI/Paper';
import { Tabs } from '../UI/Tabs';
import Text from '../UI/Text';
import AlertMessage from '../UI/AlertMessage';
import FlatButton from '../UI/FlatButton';
import RaisedButton from '../UI/RaisedButton';
import SelectField from '../UI/SelectField';
import SelectOption from '../UI/SelectOption';
import Toggle from '../UI/Toggle';
import { CompactTextAreaField } from '../UI/CompactTextAreaField';
import { ColumnStackLayout, LineStackLayout } from '../UI/Layout';
import {
  Accordion,
  AccordionBody,
  AccordionHeader,
} from '../UI/Accordion';
import { usePlaymeshLocalization } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';
import {
  isPlaymeshAiTerminalCall,
  type PlaymeshAiApprovalMode,
  type PlaymeshAiCall,
  type PlaymeshAiSession,
} from './PlaymeshAiProtocol';
import { type PlaymeshAiApprovalGrant } from './PlaymeshAiClient';
import { type PlaymeshAiFailureDiagnostic } from './PlaymeshAiDiagnostics';
import { type PlaymeshAiApprovalPresentation } from './PlaymeshAiApprovalPolicy';
import PlaymeshAiApprovalDialog from './PlaymeshAiApprovalDialog';
import { type PlaymeshAiPlan } from './PlaymeshAiLocalToolWrappers';
import {
  type PlaymeshAiPromptTemplateMode,
  type PlaymeshAiPromptTemplateState,
} from './PlaymeshAiPromptTemplateController';
import { type PlaymeshLocalizationContextValue } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';

export type PlaymeshAiSessionOperation =
  | 'idle'
  | 'opening'
  | 'copying_prompt';
export type PlaymeshAiSessionFeedback =
  | 'none'
  | 'opened_chat'
  | 'opened_agent'
  | 'cancelled'
  | 'missing_game_id'
  | 'unauthorized'
  | 'not_found'
  | 'conflict'
  | 'network_error'
  | 'clipboard_error'
  | 'local_error'
  | 'generic_error';
export type PlaymeshAiChatActionFeedback =
  | 'none'
  | 'reading_clipboard'
  | 'clipboard_empty'
  | 'clipboard_read_failed'
  | 'execution_failed';
export type PlaymeshAiAgentBaseUrlsStatus =
  | 'idle'
  | 'loading'
  | 'ready'
  | 'load_failed';
export type PlaymeshAiApprovalModeStatus =
  | 'idle'
  | 'saving'
  | 'save_failed'
  | 'uncertain';

type Props = {|
  view: 'chat' | 'agent',
  onViewChanged: ('chat' | 'agent') => void,
  session: ?PlaymeshAiSession,
  calls: Array<PlaymeshAiCall>,
  approvals: Array<PlaymeshAiApprovalPresentation>,
  approvalGrants: Array<PlaymeshAiApprovalGrant>,
  approvalGrantsStatus:
    | 'idle'
    | 'loading'
    | 'ready'
    | 'load_failed'
    | 'revoke_failed',
  approvalMode: PlaymeshAiApprovalMode,
  approvalModeStatus: PlaymeshAiApprovalModeStatus,
  plan: ?PlaymeshAiPlan,
  manualInput: string,
  onManualInputChanged: string => void,
  busy: boolean,
  canOpenSession: boolean,
  sessionOperation: PlaymeshAiSessionOperation,
  sessionFeedback: PlaymeshAiSessionFeedback,
  sessionFailure: ?PlaymeshAiFailureDiagnostic,
  eventPayloadValidation:
    | 'none'
    | 'required'
    | 'invalid',
  connectionStatus: 'online' | 'offline',
  promptTemplateState: PlaymeshAiPromptTemplateState,
  returnStatusText: string,
  returnStatusCopyFeedback: 'none' | 'copy_failed',
  chatActionFeedback: PlaymeshAiChatActionFeedback,
  agentBaseUrls: Array<string>,
  agentBaseUrl: string,
  agentBaseUrlsStatus: PlaymeshAiAgentBaseUrlsStatus,
  onRetrySession: () => void,
  onCopyPrompt: () => Promise<void>,
  onCopyReturnStatus: string => Promise<void>,
  onExecuteManual: () => Promise<void>,
  onPasteAndExecute: () => Promise<void>,
  onClearManualInput: () => void,
  onAgentBaseUrlChanged: string => void,
  onRetryAgentBaseUrls: () => Promise<void>,
  isCallCancellationDisabled: string => boolean,
  isTurnCancellationDisabled: string => boolean,
  onCancelCall: string => Promise<void>,
  onCancelTurn: string => Promise<void>,
  onApproveOnce: string => Promise<void>,
  onApproveProject: string => Promise<void>,
  onApproveAlways: string => Promise<void>,
  onReject: string => Promise<void>,
  onRefreshApprovalGrants: () => Promise<void>,
  onRevokeApprovalGrant: string => Promise<void>,
  onApprovalModeChanged: PlaymeshAiApprovalMode => Promise<void>,
  onRetryApprovalMode: () => Promise<void>,
  onPromptTemplateContentChanged: string => void,
  onRetryPromptTemplates: () => Promise<void>,
  onSavePromptTemplate: () => Promise<void>,
  onResetPromptTemplate: () => Promise<void>,
|};

const styles = {
  root: {
    flex: 1,
    minWidth: 0,
    minHeight: 0,
    overflow: 'auto',
  },
  content: {
    width: 'min(100%, 800px)',
    margin: '0 auto',
    padding: 16,
    boxSizing: 'border-box',
  },
  call: {
    width: '100%',
    minWidth: 0,
    boxSizing: 'border-box',
    padding: 12,
    border: '1px solid rgba(255, 255, 255, 0.14)',
    borderRadius: 4,
  },
  approvalActions: {
    display: 'flex',
    flexWrap: 'wrap',
    gap: 8,
    alignItems: 'center',
  },
  approvalModeSection: {
    display: 'flex',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: 8,
    width: '100%',
    minWidth: 0,
    boxSizing: 'border-box',
    padding: '2px 4px',
  },
  approvalModeFeedback: {
    display: 'flex',
    flex: '1 1 100%',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: 8,
    minWidth: 0,
  },
  callHeader: {
    display: 'flex',
    flexWrap: 'wrap',
    justifyContent: 'space-between',
    alignItems: 'center',
    gap: 8,
    minWidth: 0,
  },
  sectionBody: {
    width: '100%',
    minWidth: 0,
    maxWidth: '100%',
    boxSizing: 'border-box',
  },
  approvalGrantRow: {
    display: 'flex',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: 8,
    width: '100%',
    minWidth: 0,
  },
  approvalGrantIdentity: {
    flex: '1 1 180px',
    minWidth: 0,
    maxWidth: '100%',
  },
  approvalGrantAction: {
    flex: '0 0 auto',
    marginLeft: 'auto',
  },
  chatActionSection: {
    display: 'grid',
    gap: 16,
    width: '100%',
    minWidth: 0,
  },
  chatActions: {
    display: 'flex',
    flexWrap: 'wrap',
    gap: 8,
    alignItems: 'center',
    width: '100%',
    minWidth: 0,
  },
  promptTemplateLayout: {
    display: 'flex',
    flexWrap: 'wrap',
    gap: 12,
    width: '100%',
    minWidth: 0,
  },
  promptTemplateEditor: {
    display: 'grid',
    gap: 8,
    flex: '1 1 340px',
    minWidth: 0,
  },
  promptTemplateTextarea: {
    boxSizing: 'border-box',
    width: '100%',
    minHeight: 220,
    maxHeight: '42vh',
    resize: 'vertical',
    padding: 12,
    color: 'inherit',
    border: '1px solid rgba(255, 255, 255, 0.2)',
    borderRadius: 4,
    background: 'rgba(0, 0, 0, 0.16)',
    fontFamily: 'monospace',
    fontSize: 13,
    lineHeight: 1.5,
  },
  promptTemplateMeta: {
    display: 'flex',
    flexWrap: 'wrap',
    justifyContent: 'space-between',
    gap: 8,
    opacity: 0.78,
    fontSize: 12,
  },
  returnStatusTextarea: {
    boxSizing: 'border-box',
    width: '100%',
    minHeight: 128,
    maxHeight: '32vh',
    resize: 'vertical',
    padding: 12,
    color: 'inherit',
    border: '1px solid rgba(255, 255, 255, 0.2)',
    borderRadius: 4,
    background: 'rgba(0, 0, 0, 0.16)',
    fontFamily: 'monospace',
    fontSize: 12,
    lineHeight: 1.5,
    overflowWrap: 'anywhere',
  },
};

const agentBaseUrlLabel = (
  baseUrl: string,
  t: PlaymeshLocalizationContextValue['t']
): string => {
  const parsed = new URL(baseUrl);
  const currentOrigin = global.location ? global.location.origin : '';
  const localOnly = ['127.0.0.1', 'localhost', '[::1]'].includes(
    parsed.hostname.toLowerCase()
  );
  const suffix =
    parsed.origin === currentOrigin
      ? t(playmeshMessages.aiAgentBaseUrlCurrent)
      : localOnly
      ? t(playmeshMessages.aiAgentBaseUrlLocalOnly)
      : t(playmeshMessages.aiAgentBaseUrlLan);
  return `${baseUrl} ${suffix}`;
};

const callStateMessage = (
  call: PlaymeshAiCall,
  t: PlaymeshLocalizationContextValue['t']
): string => {
  switch (call.state) {
    case 'queued':
      return t(playmeshMessages.aiCallStateQueued);
    case 'awaiting_approval':
      return t(playmeshMessages.aiCallStateAwaitingApproval);
    case 'running':
      return t(playmeshMessages.aiRunning);
    case 'finished':
      return t(playmeshMessages.aiCallStateFinished);
    case 'failed':
      return t(playmeshMessages.aiCallStateFailed);
    case 'cancelled':
      return t(playmeshMessages.aiCallStateCancelled);
    case 'timed_out':
      return t(playmeshMessages.aiCallStateTimedOut);
    default:
      return t(playmeshMessages.aiWaiting);
  }
};

const promptTemplateStateMessage = (
  state: PlaymeshAiPromptTemplateState,
  mode: PlaymeshAiPromptTemplateMode,
  t: PlaymeshLocalizationContextValue['t']
): string => {
  const template = state.templates.find(item => item.mode === mode);
  if (state.selectedMode === mode && state.dirty) {
    return t(playmeshMessages.aiPromptTemplatesDirty);
  }
  return template && template.customized
    ? t(playmeshMessages.aiPromptTemplatesCustomized)
    : t(playmeshMessages.aiPromptTemplatesDefault);
};

const sessionFeedbackMessage = (
  feedback: PlaymeshAiSessionFeedback,
  t: PlaymeshLocalizationContextValue['t']
): string => {
  switch (feedback) {
    case 'opened_chat':
      return t(playmeshMessages.aiSessionOpenedChat);
    case 'opened_agent':
      return t(playmeshMessages.aiSessionOpenedAgent);
    case 'cancelled':
      return t(playmeshMessages.aiSessionCancelled);
    case 'missing_game_id':
      return t(playmeshMessages.aiSessionMissingGameId);
    case 'unauthorized':
      return t(playmeshMessages.aiSessionUnauthorized);
    case 'not_found':
      return t(playmeshMessages.aiSessionNotFound);
    case 'conflict':
      return t(playmeshMessages.aiSessionConflict);
    case 'network_error':
      return t(playmeshMessages.aiSessionNetworkError);
    case 'clipboard_error':
      return t(playmeshMessages.aiSessionClipboardError);
    case 'local_error':
      return t(playmeshMessages.aiSessionLocalError);
    case 'generic_error':
      return t(playmeshMessages.aiSessionGenericError);
    default:
      return '';
  }
};

const isSessionFeedbackError = (
  feedback: PlaymeshAiSessionFeedback
): boolean =>
  [
    'missing_game_id',
    'unauthorized',
    'not_found',
    'conflict',
    'network_error',
    'clipboard_error',
    'local_error',
    'generic_error',
  ].includes(feedback);

/**
 * 安全 UI 只展示工具名和受控状态，不把 raw arguments/output/error 放进
 * Tooltip、title、Markdown 或可加载远程资源的组件。
 */
export const PlaymeshAiPanel = ({
  view,
  onViewChanged,
  session,
  calls,
  approvals,
  approvalGrants,
  approvalGrantsStatus,
  approvalMode,
  approvalModeStatus,
  plan,
  manualInput,
  onManualInputChanged,
  busy,
  canOpenSession,
  sessionOperation,
  sessionFeedback,
  sessionFailure,
  eventPayloadValidation,
  connectionStatus,
  promptTemplateState,
  returnStatusText,
  returnStatusCopyFeedback,
  chatActionFeedback,
  agentBaseUrls,
  agentBaseUrl,
  agentBaseUrlsStatus,
  onRetrySession,
  onCopyPrompt,
  onCopyReturnStatus,
  onExecuteManual,
  onPasteAndExecute,
  onClearManualInput,
  onAgentBaseUrlChanged,
  onRetryAgentBaseUrls,
  isCallCancellationDisabled,
  isTurnCancellationDisabled,
  onCancelCall,
  onCancelTurn,
  onApproveOnce,
  onApproveProject,
  onApproveAlways,
  onReject,
  onRefreshApprovalGrants,
  onRevokeApprovalGrant,
  onApprovalModeChanged,
  onRetryApprovalMode,
  onPromptTemplateContentChanged,
  onRetryPromptTemplates,
  onSavePromptTemplate,
  onResetPromptTemplate,
}: Props): React.Node => {
  const { t } = usePlaymeshLocalization();
  const isOffline = connectionStatus === 'offline';
  const activeCalls = calls.filter(call => !isPlaymeshAiTerminalCall(call));
  const hasFriendlyChatFailure = !!(
    sessionFailure &&
    [
      'gdevelop.ai.chat.clipboard.read',
      'gdevelop.ai.return_status.copy',
    ].includes(sessionFailure.operation)
  );
  const promptTemplateBusy = [
    'loading',
    'saving',
    'resetting',
  ].includes(promptTemplateState.status);
  const selectedPromptTemplate = promptTemplateState.templates.find(
    item => item.mode === view
  );
  const selectedPromptTemplateForMode =
    selectedPromptTemplate && promptTemplateState.selectedMode === view
      ? selectedPromptTemplate
      : null;

  return (
    <Paper square background="medium" style={styles.root}>
      <div style={styles.content}>
        <ColumnStackLayout noMargin useLargeSpacer>
          <Text size="title">{t(playmeshMessages.aiTitle)}</Text>
          <Tabs
            value={view}
            onChange={onViewChanged}
            options={[
              {
                value: 'chat',
                label: t(playmeshMessages.aiChat),
                id: 'playmesh-ai-chat-tab',
              },
              {
                value: 'agent',
                label: t(playmeshMessages.aiAgent),
                id: 'playmesh-ai-agent-tab',
              },
            ]}
          />
          <section
            id="playmesh-ai-approval-mode"
            aria-label={t(playmeshMessages.aiApprovalModeTitle)}
            style={styles.approvalModeSection}
          >
            <Toggle
              labelPosition="right"
              label={t(
                approvalMode === 'always_allow'
                  ? playmeshMessages.aiApprovalModeAlways
                  : playmeshMessages.aiApprovalModeRequest
              )}
              toggled={approvalMode === 'always_allow'}
              onToggle={(event, toggled) =>
                onApprovalModeChanged(
                  toggled ? 'always_allow' : 'request_approval'
                )
              }
              disabled={
                !session ||
                approvalModeStatus === 'saving' ||
                approvalModeStatus === 'uncertain'
              }
            />
            {approvalModeStatus !== 'idle' && (
              <div
                role="status"
                aria-live="polite"
                style={styles.approvalModeFeedback}
              >
                {approvalModeStatus === 'saving' && (
                  <Text noMargin color="secondary">
                    {t(playmeshMessages.aiApprovalModeSaving)}
                  </Text>
                )}
                {approvalModeStatus === 'save_failed' && (
                  <AlertMessage kind="warning">
                    {t(playmeshMessages.aiApprovalModeSaveFailed)}
                  </AlertMessage>
                )}
                {approvalModeStatus === 'uncertain' && (
                  <AlertMessage kind="warning">
                    {t(playmeshMessages.aiApprovalModeUncertain)}
                  </AlertMessage>
                )}
                {approvalModeStatus === 'uncertain' && (
                  <FlatButton
                    label={t(playmeshMessages.aiApprovalModeRetry)}
                    onClick={onRetryApprovalMode}
                  />
                )}
              </div>
            )}
          </section>
          {isOffline && (
            <AlertMessage kind="warning">
              {t(playmeshMessages.aiOffline)}
            </AlertMessage>
          )}
          {eventPayloadValidation === 'required' &&
            !(view === 'chat' && session) && (
            <AlertMessage kind="warning">
              {t(playmeshMessages.aiEventPayloadRequired)}
            </AlertMessage>
          )}
          {eventPayloadValidation === 'invalid' &&
            !(view === 'chat' && session) && (
            <AlertMessage kind="warning">
              {t(playmeshMessages.aiEventPayloadInvalid)}
            </AlertMessage>
          )}
          {view === 'agent' && (
            <AlertMessage kind="info">
              {t(playmeshMessages.aiTokenNotice)}
            </AlertMessage>
          )}
          {view === 'agent' && (
            <>
              <section
                aria-label={t(playmeshMessages.aiAgentBaseUrl)}
                style={styles.sectionBody}
              >
                {(agentBaseUrlsStatus === 'idle' ||
                  agentBaseUrlsStatus === 'loading') && (
                  <div role="status" aria-live="polite">
                    <Text>{t(playmeshMessages.aiAgentBaseUrlsLoading)}</Text>
                  </div>
                )}
                {agentBaseUrlsStatus === 'load_failed' && (
                  <>
                    <AlertMessage kind="warning">
                      {t(playmeshMessages.aiAgentBaseUrlsLoadFailed)}
                    </AlertMessage>
                    <FlatButton
                      label={t(playmeshMessages.aiAgentBaseUrlsRetry)}
                      onClick={onRetryAgentBaseUrls}
                      disabled={busy}
                    />
                  </>
                )}
                {agentBaseUrlsStatus === 'ready' && (
                  <SelectField
                    id="playmesh-ai-agent-base-url"
                    fullWidth
                    floatingLabelText={t(playmeshMessages.aiAgentBaseUrl)}
                    helperMarkdownText={t(
                      playmeshMessages.aiAgentBaseUrlHelp
                    )}
                    value={agentBaseUrl}
                    onChange={(event, index, value) =>
                      onAgentBaseUrlChanged(value)
                    }
                    disabled={busy}
                  >
                    {agentBaseUrls.map(baseUrl => (
                      <SelectOption
                        key={baseUrl}
                        value={baseUrl}
                        label={agentBaseUrlLabel(baseUrl, t)}
                        shouldNotTranslate
                      />
                    ))}
                  </SelectField>
                )}
              </section>
            </>
          )}
          {!session && !canOpenSession && sessionFeedback === 'none' && (
            <AlertMessage kind="warning">
              {t(playmeshMessages.aiSessionMissingGameId)}
            </AlertMessage>
          )}
          {!session && sessionOperation === 'opening' && (
            <AlertMessage kind="info">
              {t(playmeshMessages.aiOpeningSession)}
            </AlertMessage>
          )}
          {sessionFeedback !== 'none' && (
            <AlertMessage
              kind={isSessionFeedbackError(sessionFeedback) ? 'error' : 'info'}
            >
              {sessionFeedbackMessage(sessionFeedback, t)}
            </AlertMessage>
          )}
          {sessionFailure && !(view === 'chat' && session) && (
            <Text color="secondary">
              {t(playmeshMessages.aiSessionDiagnostic, {
                operation: sessionFailure.operation,
                status:
                  sessionFailure.status > 0
                    ? String(sessionFailure.status)
                    : t(playmeshMessages.aiSessionDiagnosticLocal),
                code: sessionFailure.code,
                stage: sessionFailure.stage,
                reason: sessionFailure.reason,
                requestId: sessionFailure.requestId,
                errorType: sessionFailure.errorType,
              })}
            </Text>
          )}
          <Accordion costlyBody>
            <AccordionHeader>
              <Text size="block-title">
                {t(playmeshMessages.aiPromptTemplatesTitle)}
              </Text>
            </AccordionHeader>
            <AccordionBody>
              <section
                style={styles.sectionBody}
                aria-label={t(playmeshMessages.aiPromptTemplatesTitle)}
              >
                <ColumnStackLayout noMargin>
                  {(promptTemplateState.status === 'idle' ||
                    promptTemplateState.status === 'loading') && (
                    <Text>{t(playmeshMessages.aiPromptTemplatesLoading)}</Text>
                  )}
                  {promptTemplateState.status === 'load_failed' && (
                    <>
                      <AlertMessage kind="warning">
                        {t(playmeshMessages.aiPromptTemplatesLoadFailed)}
                      </AlertMessage>
                      <FlatButton
                        label={t(playmeshMessages.aiPromptTemplatesRetry)}
                        onClick={onRetryPromptTemplates}
                      />
                    </>
                  )}
                  {promptTemplateState.status === 'save_failed' && (
                    <AlertMessage kind="warning">
                      {t(playmeshMessages.aiPromptTemplatesSaveFailed)}
                    </AlertMessage>
                  )}
                  {promptTemplateState.status === 'reset_failed' && (
                    <AlertMessage kind="warning">
                      {t(playmeshMessages.aiPromptTemplatesResetFailed)}
                    </AlertMessage>
                  )}
                  {selectedPromptTemplateForMode && (
                    <div style={styles.promptTemplateLayout}>
                      <div
                        id="playmesh-ai-prompt-editor"
                        role="region"
                        aria-label={selectedPromptTemplateForMode.name}
                        style={styles.promptTemplateEditor}
                      >
                        <label htmlFor="playmesh-ai-prompt-content">
                          {t(playmeshMessages.aiPromptTemplatesContentLabel)}
                        </label>
                        <textarea
                          id="playmesh-ai-prompt-content"
                          value={promptTemplateState.content}
                          onChange={event =>
                            onPromptTemplateContentChanged(
                              event.currentTarget.value
                            )
                          }
                          disabled={promptTemplateBusy}
                          spellCheck={false}
                          autoComplete="off"
                          aria-describedby="playmesh-ai-prompt-status"
                          style={styles.promptTemplateTextarea}
                        />
                        <div
                          id="playmesh-ai-prompt-status"
                          role="status"
                          aria-live="polite"
                          style={styles.promptTemplateMeta}
                        >
                          <span>
                            {promptTemplateStateMessage(
                              promptTemplateState,
                              promptTemplateState.selectedMode,
                              t
                            )}
                          </span>
                          <span>
                            {t(playmeshMessages.aiPromptTemplatesSize, {
                              bytes: promptTemplateState.contentBytes,
                              maxBytes: promptTemplateState.maxContentBytes,
                            })}
                          </span>
                        </div>
                        {promptTemplateState.validationError === 'empty' && (
                          <AlertMessage kind="error">
                            {t(playmeshMessages.aiPromptTemplatesEmpty)}
                          </AlertMessage>
                        )}
                        {promptTemplateState.validationError ===
                          'too_large' && (
                          <AlertMessage kind="error">
                            {t(playmeshMessages.aiPromptTemplatesTooLarge)}
                          </AlertMessage>
                        )}
                        <LineStackLayout noMargin>
                          <FlatButton
                            label={t(
                              playmeshMessages.aiPromptTemplatesReset
                            )}
                            onClick={onResetPromptTemplate}
                            disabled={
                              promptTemplateBusy ||
                              (!promptTemplateState.customized &&
                                !promptTemplateState.dirty)
                            }
                          />
                          <RaisedButton
                            primary
                            label={t(playmeshMessages.aiPromptTemplatesSave)}
                            onClick={onSavePromptTemplate}
                            disabled={
                              promptTemplateBusy ||
                              !promptTemplateState.dirty ||
                              !!promptTemplateState.validationError
                            }
                          />
                        </LineStackLayout>
                      </div>
                    </div>
                  )}
                </ColumnStackLayout>
              </section>
            </AccordionBody>
          </Accordion>
          <LineStackLayout noMargin>
            {session && (
              <RaisedButton
                primary
                label={t(playmeshMessages.aiCopyPrompt)}
                onClick={onCopyPrompt}
                disabled={
                  busy ||
                  (view === 'agent' &&
                    (agentBaseUrlsStatus !== 'ready' || !agentBaseUrl))
                }
              />
            )}
            {!session &&
              !!sessionFailure &&
              sessionOperation === 'idle' &&
              canOpenSession && (
                <RaisedButton
                  primary
                  label={t(playmeshMessages.aiRetrySession)}
                  onClick={onRetrySession}
                  disabled={busy}
                />
              )}
          </LineStackLayout>
          {view === 'chat' && session && (
            <>
              <CompactTextAreaField
                label={t(playmeshMessages.aiChat)}
                value={manualInput}
                onChange={onManualInputChanged}
                rows={8}
                disabled={busy}
              />
              <section style={styles.chatActionSection}>
                <div>
                  <RaisedButton
                    primary
                    label={t(playmeshMessages.aiExecute)}
                    onClick={onExecuteManual}
                    disabled={!manualInput.trim() || busy}
                  />
                </div>
                <div
                  role="group"
                  aria-label={t(playmeshMessages.aiChatActions)}
                  style={styles.chatActions}
                >
                  <FlatButton
                    label={t(playmeshMessages.aiPasteAndExecute)}
                    onClick={onPasteAndExecute}
                    disabled={
                      busy ||
                      chatActionFeedback === 'reading_clipboard'
                    }
                  />
                  <FlatButton
                    label={t(playmeshMessages.aiReturnStatusCopy)}
                    onClick={() => onCopyReturnStatus(returnStatusText)}
                    disabled={!returnStatusText}
                  />
                  <FlatButton
                    label={t(playmeshMessages.aiClearInput)}
                    onClick={onClearManualInput}
                  />
                </div>
                {chatActionFeedback === 'reading_clipboard' && (
                  <div role="status" aria-live="polite">
                    <Text color="secondary">
                      {t(playmeshMessages.aiReadingClipboard)}
                    </Text>
                  </div>
                )}
                {chatActionFeedback === 'clipboard_empty' && (
                  <AlertMessage kind="warning">
                    {t(playmeshMessages.aiClipboardEmpty)}
                  </AlertMessage>
                )}
                {eventPayloadValidation === 'required' && (
                  <AlertMessage kind="warning">
                    {t(playmeshMessages.aiEventPayloadRequired)}
                  </AlertMessage>
                )}
                {eventPayloadValidation === 'invalid' && (
                  <AlertMessage kind="warning">
                    {t(playmeshMessages.aiEventPayloadInvalid)}
                  </AlertMessage>
                )}
                {chatActionFeedback === 'clipboard_read_failed' && (
                  <AlertMessage kind="error">
                    {t(playmeshMessages.aiClipboardReadFailed)}
                  </AlertMessage>
                )}
                {chatActionFeedback === 'execution_failed' && (
                  <AlertMessage kind="error">
                    {t(playmeshMessages.aiExecutionFailed)}
                  </AlertMessage>
                )}
                {returnStatusCopyFeedback === 'copy_failed' && (
                  <AlertMessage kind="error">
                    {t(playmeshMessages.aiReturnStatusCopyFailed)}
                  </AlertMessage>
                )}
                {sessionFailure && !hasFriendlyChatFailure && (
                  <AlertMessage kind="error">
                    {t(playmeshMessages.aiSessionDiagnostic, {
                      operation: sessionFailure.operation,
                      status:
                        sessionFailure.status > 0
                          ? String(sessionFailure.status)
                          : t(playmeshMessages.aiSessionDiagnosticLocal),
                      code: sessionFailure.code,
                      stage: sessionFailure.stage,
                      reason: sessionFailure.reason,
                      requestId: sessionFailure.requestId,
                      errorType: sessionFailure.errorType,
                    })}
                  </AlertMessage>
                )}
              </section>
            </>
          )}
          {view === 'chat' && session && (
            <Accordion defaultExpanded costlyBody>
              <AccordionHeader>
                <Text size="block-title">
                  {t(playmeshMessages.aiReturnStatusTitle)}
                </Text>
              </AccordionHeader>
              <AccordionBody>
                <section
                  style={styles.sectionBody}
                  aria-label={t(playmeshMessages.aiReturnStatusTitle)}
                >
                  <ColumnStackLayout noMargin>
                    <textarea
                      value={returnStatusText}
                      readOnly
                      spellCheck={false}
                      aria-label={t(playmeshMessages.aiReturnStatusTitle)}
                      style={styles.returnStatusTextarea}
                    />
                  </ColumnStackLayout>
                </section>
              </AccordionBody>
            </Accordion>
          )}
          {session && plan && (
            <Accordion defaultExpanded costlyBody>
              <AccordionHeader>
                <Text size="block-title">
                  {t(playmeshMessages.aiPlanTitle)}
                </Text>
              </AccordionHeader>
              <AccordionBody>
                <div style={styles.sectionBody}>
                  <ColumnStackLayout noMargin>
                    {!!plan.explanation && <Text>{plan.explanation}</Text>}
                    {plan.plan.map((item, index: number) => (
                      <div key={`${index}:${item.step}`} style={styles.call}>
                        <ColumnStackLayout noMargin>
                          <Text>{item.step}</Text>
                          <Text color="secondary">
                            {item.status === 'completed'
                              ? t(playmeshMessages.aiPlanCompleted)
                              : item.status === 'in_progress'
                              ? t(playmeshMessages.aiPlanInProgress)
                              : t(playmeshMessages.aiPlanPending)}
                          </Text>
                        </ColumnStackLayout>
                      </div>
                    ))}
                  </ColumnStackLayout>
                </div>
              </AccordionBody>
            </Accordion>
          )}
          {activeCalls.map(call => (
            <div key={call.callId} style={styles.call}>
              <div style={styles.callHeader}>
                <ColumnStackLayout noMargin>
                  <Text>{call.toolName}</Text>
                  <Text color="secondary">
                    {callStateMessage(call, t)}
                  </Text>
                </ColumnStackLayout>
                {!isPlaymeshAiTerminalCall(call) && (
                  <div
                    role="group"
                    aria-label={t(playmeshMessages.aiCallActions)}
                    style={styles.approvalActions}
                  >
                    <FlatButton
                      label={t(playmeshMessages.aiCancelCall)}
                      onClick={() => onCancelCall(call.callId)}
                      disabled={
                        busy || isCallCancellationDisabled(call.callId)
                      }
                    />
                    <FlatButton
                      label={t(playmeshMessages.aiCancel)}
                      onClick={() => onCancelTurn(call.turnId)}
                      disabled={
                        busy || isTurnCancellationDisabled(call.turnId)
                      }
                    />
                  </div>
                )}
              </div>
            </div>
          ))}
          <PlaymeshAiApprovalDialog
            approvals={approvals}
            busy={busy}
            onApproveOnce={onApproveOnce}
            onApproveProject={onApproveProject}
            onApproveAlways={onApproveAlways}
            onReject={onReject}
          />
          <Accordion costlyBody>
            <AccordionHeader>
              <Text size="block-title">
                {t(playmeshMessages.aiApprovalGrantsTitle)}
              </Text>
            </AccordionHeader>
            <AccordionBody>
              <section
                id="playmesh-ai-approval-grants"
                aria-label={t(playmeshMessages.aiApprovalGrantsTitle)}
                style={styles.sectionBody}
              >
                <ColumnStackLayout noMargin>
                  {approvalGrantsStatus === 'load_failed' && (
                    <AlertMessage kind="warning">
                      {t(playmeshMessages.aiApprovalGrantsLoadFailed)}
                    </AlertMessage>
                  )}
                  {approvalGrantsStatus === 'revoke_failed' && (
                    <AlertMessage kind="warning">
                      {t(playmeshMessages.aiApprovalGrantRevokeFailed)}
                    </AlertMessage>
                  )}
                  {approvalGrantsStatus === 'ready' &&
                    approvalGrants.length === 0 && (
                      <Text>{t(playmeshMessages.aiApprovalGrantsEmpty)}</Text>
                    )}
                  {approvalGrants.map(grant => (
                    <div key={grant.grantId} style={styles.call}>
                      <div style={styles.approvalGrantRow}>
                        <div style={styles.approvalGrantIdentity}>
                          <Text
                            noMargin
                            allowSelection
                            style={{
                              overflowWrap: 'anywhere',
                              fontFamily: '"Lucida Console", Monaco, monospace',
                            }}
                          >
                            {grant.operationId}
                          </Text>
                          <Text
                            noMargin
                            allowSelection
                            color="secondary"
                            style={{ overflowWrap: 'anywhere' }}
                          >
                            {`${grant.scopeKind} · ${grant.scopeId}`}
                          </Text>
                        </div>
                        <div style={styles.approvalGrantAction}>
                          <FlatButton
                            label={t(playmeshMessages.aiApprovalGrantRevoke)}
                            onClick={() =>
                              onRevokeApprovalGrant(grant.grantId)
                            }
                            disabled={
                              busy || approvalGrantsStatus === 'loading'
                            }
                          />
                        </div>
                      </div>
                    </div>
                  ))}
                  <FlatButton
                    label={t(playmeshMessages.aiApprovalGrantsRefresh)}
                    onClick={onRefreshApprovalGrants}
                    disabled={busy || approvalGrantsStatus === 'loading'}
                  />
                </ColumnStackLayout>
              </section>
            </AccordionBody>
          </Accordion>
        </ColumnStackLayout>
      </div>
    </Paper>
  );
};

export default PlaymeshAiPanel;
