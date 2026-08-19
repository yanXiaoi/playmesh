// @flow

import * as React from 'react';
import Dialog from '../UI/Dialog';
import FlatButton from '../UI/FlatButton';
import RaisedButton from '../UI/RaisedButton';
import Text from '../UI/Text';
import { ColumnStackLayout } from '../UI/Layout';
import { usePlaymeshLocalization } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';
import { type PlaymeshLocalizationContextValue } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { type PlaymeshAiApprovalPresentation } from './PlaymeshAiApprovalPolicy';

type Props = {|
  approvals: $ReadOnlyArray<PlaymeshAiApprovalPresentation>,
  busy: boolean,
  onApproveOnce: string => Promise<void>,
  onApproveProject: string => Promise<void>,
  onApproveAlways: string => Promise<void>,
  onReject: string => Promise<void>,
|};

const styles = {
  actions: {
    display: 'flex',
    flexWrap: 'wrap',
    gap: 8,
    alignItems: 'center',
    justifyContent: 'flex-end',
    width: '100%',
    minWidth: 0,
  },
  rejectAction: {
    marginRight: 'auto',
  },
  summary: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))',
    gap: 12,
    padding: 12,
    border: '1px solid rgba(255, 255, 255, 0.16)',
    borderRadius: 4,
    background: 'rgba(255, 255, 255, 0.05)',
  },
  summaryValue: {
    marginTop: 4,
    minWidth: 0,
    overflowWrap: 'anywhere',
    fontWeight: 600,
  },
  toolName: {
    fontFamily: 'monospace',
  },
  details: {
    display: 'grid',
    gap: 8,
    margin: 0,
    minWidth: 0,
  },
  detailRow: {
    display: 'grid',
    gridTemplateColumns: 'minmax(104px, 0.32fr) minmax(0, 1fr)',
    gap: 8,
    minWidth: 0,
  },
  term: {
    margin: 0,
    opacity: 0.72,
  },
  description: {
    margin: 0,
    minWidth: 0,
    overflowWrap: 'anywhere',
  },
  arguments: {
    margin: 0,
    paddingInlineStart: 18,
  },
};

const approvalRiskMessage = (
  risk: string,
  t: PlaymeshLocalizationContextValue['t']
): string =>
  risk === 'high'
    ? t(playmeshMessages.aiApprovalRiskHigh)
    : risk === 'medium'
    ? t(playmeshMessages.aiApprovalRiskMedium)
    : risk === 'low'
    ? t(playmeshMessages.aiApprovalRiskLow)
    : risk;

/**
 * A single modal owns the visible approval. Poll refreshes keep the same ID
 * pinned, while concurrent requests wait their turn instead of stacking
 * multiple dialogs. The user must explicitly approve or reject the request.
 */
export const PlaymeshAiApprovalDialog = ({
  approvals,
  busy,
  onApproveOnce,
  onApproveProject,
  onApproveAlways,
  onReject,
}: Props): React.Node => {
  const { t } = usePlaymeshLocalization();
  const [pinnedApprovalId, setPinnedApprovalId] = React.useState<?string>(null);
  const [
    decisionInFlightApprovalId,
    setDecisionInFlightApprovalId,
  ] = React.useState<?string>(null);
  const decisionInFlightRef = React.useRef<boolean>(false);
  const mountedRef = React.useRef<boolean>(true);

  const approval =
    approvals.find(item => item.approvalId === pinnedApprovalId) ||
    approvals[0] ||
    null;
  const approvalId = approval ? approval.approvalId : null;

  React.useEffect(
    () => {
      if (approvalId !== pinnedApprovalId) {
        setPinnedApprovalId(approvalId);
      }
    },
    [approvalId, pinnedApprovalId]
  );

  React.useEffect(
    () => {
      mountedRef.current = true;
      return () => {
        mountedRef.current = false;
      };
    },
    []
  );

  if (!approval) return null;

  const decide = async (decision: string => Promise<void>): Promise<void> => {
    if (decisionInFlightRef.current) return;
    decisionInFlightRef.current = true;
    setDecisionInFlightApprovalId(approval.approvalId);
    try {
      await decision(approval.approvalId);
    } finally {
      decisionInFlightRef.current = false;
      if (mountedRef.current) setDecisionInFlightApprovalId(null);
    }
  };

  const decisionDisabled = busy || decisionInFlightApprovalId !== null;
  const riskLabel = approvalRiskMessage(approval.risk, t);

  return (
    <Dialog
      key={approval.approvalId}
      id="playmesh-ai-approval-dialog"
      open
      title={t(playmeshMessages.aiApprovalDetailsTitle)}
      subtitle={t(playmeshMessages.aiCallStateAwaitingApproval)}
      maxWidth="sm"
      dangerLevel={approval.risk === 'high' ? 'danger' : 'warning'}
      cannotBeDismissed
      actionsFullWidthOnMobile
      actions={[
        <div
          key="approval-actions"
          role="group"
          aria-label={t(playmeshMessages.aiApprovalDetailsTitle)}
          style={styles.actions}
        >
          <div style={styles.rejectAction}>
            <FlatButton
              label={t(playmeshMessages.aiReject)}
              onClick={() => decide(onReject)}
              disabled={decisionDisabled}
            />
          </div>
          <FlatButton
            label={t(playmeshMessages.aiApproveAlways)}
            onClick={() => decide(onApproveAlways)}
            disabled={decisionDisabled}
          />
          <FlatButton
            label={t(playmeshMessages.aiApproveProject)}
            onClick={() => decide(onApproveProject)}
            disabled={decisionDisabled}
          />
          <RaisedButton
            primary
            label={t(playmeshMessages.aiApprove)}
            onClick={() => decide(onApproveOnce)}
            disabled={decisionDisabled}
          />
        </div>,
      ]}
    >
      <ColumnStackLayout noMargin useLargeSpacer>
        <div style={styles.summary} role="status">
          <div>
            <Text noMargin color="secondary">
              {t(playmeshMessages.aiApprovalTool)}
            </Text>
            <div style={{ ...styles.summaryValue, ...styles.toolName }}>
              {approval.toolName}
            </div>
          </div>
          <div>
            <Text noMargin color="secondary">
              {t(playmeshMessages.aiApprovalRisk)}
            </Text>
            <div style={styles.summaryValue}>{riskLabel}</div>
          </div>
        </div>

        <dl style={styles.details}>
          {!!approval.riskReason && (
            <div style={styles.detailRow}>
              <dt style={styles.term}>
                {t(playmeshMessages.aiApprovalRiskReason)}
              </dt>
              <dd style={styles.description}>{approval.riskReason}</dd>
            </div>
          )}
          {approval.affectedSceneIds.length > 0 && (
            <div style={styles.detailRow}>
              <dt style={styles.term}>
                {t(playmeshMessages.aiApprovalAffectedScenes)}
              </dt>
              <dd style={styles.description}>
                {approval.affectedSceneIds.join(', ')}
              </dd>
            </div>
          )}
          {approval.affectedObjectIds.length > 0 && (
            <div style={styles.detailRow}>
              <dt style={styles.term}>
                {t(playmeshMessages.aiApprovalAffectedObjects)}
              </dt>
              <dd style={styles.description}>
                {approval.affectedObjectIds.join(', ')}
              </dd>
            </div>
          )}
          {approval.affectedResourceIds.length > 0 && (
            <div style={styles.detailRow}>
              <dt style={styles.term}>
                {t(playmeshMessages.aiApprovalAffectedResources)}
              </dt>
              <dd style={styles.description}>
                {approval.affectedResourceIds.join(', ')}
              </dd>
            </div>
          )}
          {approval.arguments.length > 0 && (
            <div style={styles.detailRow}>
              <dt style={styles.term}>
                {t(playmeshMessages.aiApprovalArguments)}
              </dt>
              <dd style={styles.description}>
                <ul style={styles.arguments}>
                  {approval.arguments.map((argument, index: number) => (
                    <li key={`${index}:${argument.name}`}>
                      {`${argument.name}: ${argument.value}`}
                    </li>
                  ))}
                </ul>
                {approval.argumentsTruncated && (
                  <Text color="secondary">
                    {t(playmeshMessages.aiApprovalArgumentsTruncated)}
                  </Text>
                )}
              </dd>
            </div>
          )}
          <div style={styles.detailRow}>
            <dt style={styles.term}>
              {t(playmeshMessages.aiApprovalMutation)}
            </dt>
            <dd style={styles.description}>
              {approval.modifiesProject
                ? t(playmeshMessages.aiApprovalMutationProject)
                : t(playmeshMessages.aiApprovalMutationReadOnly)}
            </dd>
          </div>
        </dl>
      </ColumnStackLayout>
    </Dialog>
  );
};

export default PlaymeshAiApprovalDialog;
