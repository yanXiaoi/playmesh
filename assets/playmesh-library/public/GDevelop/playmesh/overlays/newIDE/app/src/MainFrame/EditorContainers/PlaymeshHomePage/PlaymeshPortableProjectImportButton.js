// @flow
import * as React from 'react';
import { Trans } from '@lingui/macro';
import Dialog from '../../../UI/Dialog';
import FlatButton from '../../../UI/FlatButton';
import AlertMessage from '../../../UI/AlertMessage';
import PlaceholderLoader from '../../../UI/PlaceholderLoader';
import Text from '../../../UI/Text';
import { ColumnStackLayout } from '../../../UI/Layout';
import {
  type FileMetadata,
  type FileMetadataAndStorageProviderName,
} from '../../../ProjectsStorage';
import { importPortableProjectWithCopyDecision } from '../../../PlaymeshProjectImport/PlaymeshPortableProjectImportController';
import { usePlaymeshLocalization } from '../../../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../../../PlaymeshLocalization/PlaymeshMessageKeys';

type Props = {|
  onOpenProject: (file: FileMetadataAndStorageProviderName) => Promise<void>,
  disabled: boolean,
|};

const PlaymeshPortableProjectImportButton = ({
  onOpenProject,
  disabled,
}: Props): React.Node => {
  const { t: playmeshT } = usePlaymeshLocalization();
  const inputRef = React.useRef<?HTMLInputElement>(null);
  const [importing, setImporting] = React.useState(false);
  const [errorMessage, setErrorMessage] = React.useState<?string>(null);

  const importArchive = async (archiveBlob: Blob): Promise<void> => {
    setErrorMessage(null);
    setImporting(true);
    try {
      const result = await importPortableProjectWithCopyDecision({
        archiveBlob,
        confirmCopy: ({ sourcePackageName, suggestedPackageName }) =>
          window.confirm(
            playmeshT(playmeshMessages.projectImportCopyConfirm, {
              sourceId: sourcePackageName,
              newId: suggestedPackageName,
            })
          ),
      });
      if (result.status === 'cancelled') return;
      if (result.status === 'recovering') {
        setErrorMessage(playmeshT(playmeshMessages.projectImportRecovery));
        return;
      }
      const rawFileMetadata /*: any */ = result.fileMetadata;
      if (
        result.status !== 'imported' ||
        !rawFileMetadata ||
        typeof rawFileMetadata !== 'object' ||
        typeof rawFileMetadata.fileIdentifier !== 'string'
      ) {
        throw new Error('GDevelop import did not return an imported project.');
      }
      const fileMetadata: FileMetadata = rawFileMetadata;
      await onOpenProject({
        storageProviderName: 'PlaymeshLocal',
        fileMetadata,
      });
    } catch (error) {
      const details = error instanceof Error ? error.message : String(error);
      setErrorMessage(
        `${playmeshT(playmeshMessages.projectImportFailed)}${
          details ? ` ${details}` : ''
        }`
      );
    } finally {
      setImporting(false);
    }
  };

  return (
    <>
      <FlatButton
        label={playmeshT(
          importing
            ? playmeshMessages.projectImporting
            : playmeshMessages.homeImportGDevelopZip
        )}
        disabled={disabled || importing}
        onClick={() => {
          if (inputRef.current) inputRef.current.click();
        }}
      />
      <input
        ref={inputRef}
        type="file"
        accept=".zip,application/zip,application/x-zip-compressed"
        style={{ display: 'none' }}
        onChange={event => {
          const file =
            event.currentTarget.files && event.currentTarget.files[0];
          event.currentTarget.value = '';
          if (file) importArchive(file);
        }}
      />
      <Dialog
        open={importing || !!errorMessage}
        title={playmeshT(playmeshMessages.projectImportTitle)}
        actions={
          importing
            ? []
            : [
                <FlatButton
                  key="close"
                  label={<Trans>Close</Trans>}
                  onClick={() => setErrorMessage(null)}
                />,
              ]
        }
        onRequestClose={() => {
          if (!importing) setErrorMessage(null);
        }}
        maxWidth="sm"
      >
        {importing ? (
          <ColumnStackLayout noMargin alignItems="center">
            <PlaceholderLoader />
            <Text>{playmeshT(playmeshMessages.projectImporting)}</Text>
          </ColumnStackLayout>
        ) : (
          <AlertMessage kind="error">{errorMessage || ''}</AlertMessage>
        )}
      </Dialog>
    </>
  );
};

export default PlaymeshPortableProjectImportButton;
