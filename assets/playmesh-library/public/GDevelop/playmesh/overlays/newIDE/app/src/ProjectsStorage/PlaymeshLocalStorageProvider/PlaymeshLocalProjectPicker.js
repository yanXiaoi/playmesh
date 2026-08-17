// @flow
import * as React from 'react';
import { Trans } from '@lingui/macro';
import Dialog from '../../UI/Dialog';
import FlatButton from '../../UI/FlatButton';
import RaisedButton from '../../UI/RaisedButton';
import Text from '../../UI/Text';
import AlertMessage from '../../UI/AlertMessage';
import { ColumnStackLayout, LineStackLayout } from '../../UI/Layout';
import { type PlaymeshManagedProjectListDiagnostic } from '../../PlaymeshProjects/PlaymeshProjectLifecycleClient';
import { usePlaymeshLocalization } from '../../PlaymeshLocalization/PlaymeshLocalizationProvider';
import {
  playmeshMessages,
  type PlaymeshMessageKey,
} from '../../PlaymeshLocalization/PlaymeshMessageKeys';

export type PlaymeshProjectPickerItem = {|
  id: string,
  name: string,
  gameId?: string,
  savedAt: number,
  hasCurrent?: boolean,
|};

type Props = {|
  projects: Array<PlaymeshProjectPickerItem>,
  diagnostics: Array<PlaymeshManagedProjectListDiagnostic>,
  onChoose: PlaymeshProjectPickerItem => void,
  onClose: () => void,
|};

const diagnosticMessageKey = (code: string): PlaymeshMessageKey => {
  switch (code) {
    case 'project_metadata_unreadable':
      return playmeshMessages.projectPickerDiagnosticMetadataUnreadable;
    case 'project_metadata_invalid':
      return playmeshMessages.projectPickerDiagnosticMetadataInvalid;
    case 'project_root_identity_mismatch':
      return playmeshMessages.projectPickerDiagnosticRootIdentityMismatch;
    case 'gdevelop_metadata_invalid':
      return playmeshMessages.projectPickerDiagnosticGdevelopMetadataInvalid;
    case 'gdevelop_current_evidence_unavailable':
      return playmeshMessages.projectPickerDiagnosticCurrentEvidenceUnavailable;
    default:
      return playmeshMessages.projectPickerDiagnosticUnknown;
  }
};

const PlaymeshLocalProjectPicker = ({
  projects,
  diagnostics,
  onChoose,
  onClose,
}: Props): React.Node => {
  const { t: playmeshT } = usePlaymeshLocalization();

  return (
    <Dialog
      open
      title={playmeshT(playmeshMessages.projectPickerTitle)}
      actions={[
        <FlatButton
          key="cancel"
          label={<Trans>Cancel</Trans>}
          onClick={onClose}
        />,
      ]}
      onRequestClose={onClose}
      maxWidth="sm"
    >
      <ColumnStackLayout noMargin>
        {!!diagnostics.length && (
          <AlertMessage kind="warning">
            <ColumnStackLayout noMargin>
              <Text>
                {playmeshT(playmeshMessages.projectPickerDiagnosticsTitle)}
              </Text>
              {diagnostics.map((diagnostic, index) => (
                <Text key={`${diagnostic.code}:${diagnostic.entry}:${index}`}>
                  {playmeshT(diagnosticMessageKey(diagnostic.code), {
                    entry: diagnostic.entry,
                    code: diagnostic.code,
                  })}
                </Text>
              ))}
            </ColumnStackLayout>
          </AlertMessage>
        )}
        {projects.length ? (
          <ColumnStackLayout noMargin>
            {projects.map(project => {
              const hasNoCurrent = project.hasCurrent === false;
              return (
                <LineStackLayout key={project.id} noMargin alignItems="center">
                  <ColumnStackLayout noMargin expand>
                    <RaisedButton
                      label={project.name}
                      onClick={() => onChoose(project)}
                      disabled={hasNoCurrent}
                    />
                    {hasNoCurrent && (
                      <Text color="secondary">
                        {playmeshT(playmeshMessages.projectPickerNoCurrent)}
                      </Text>
                    )}
                  </ColumnStackLayout>
                </LineStackLayout>
              );
            })}
          </ColumnStackLayout>
        ) : (
          <Text>{playmeshT(playmeshMessages.projectPickerEmpty)}</Text>
        )}
      </ColumnStackLayout>
    </Dialog>
  );
};

export default PlaymeshLocalProjectPicker;
