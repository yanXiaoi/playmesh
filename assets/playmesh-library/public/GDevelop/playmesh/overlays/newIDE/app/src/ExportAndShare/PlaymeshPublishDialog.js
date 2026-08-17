// @flow
import * as React from 'react';
import { I18n } from '@lingui/react';

import Dialog from '../UI/Dialog';
import FlatButton from '../UI/FlatButton';
import RaisedButton from '../UI/RaisedButton';
import AlertMessage from '../UI/AlertMessage';
import Text from '../UI/Text';
import { ColumnStackLayout } from '../UI/Layout';
import EventsFunctionsExtensionsContext from '../EventsFunctionsExtensionsLoader/EventsFunctionsExtensionsContext';
import {
  createPlaymeshGDevelopPublishFileMap,
  PlaymeshPublishError,
} from './PlaymeshPublishController';
import {
  supportsPlaymeshStreamingUpload,
  uploadPlaymeshPackageBlob,
  uploadPlaymeshPackageStream,
} from './PlaymeshPackageUploader';
import { usePlaymeshLocalization } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';
import type { PlaymeshMessageKey } from '../PlaymeshLocalization/PlaymeshMessageKeys';
import type { FileMetadata } from '../ProjectsStorage';
import type { PlaymeshPreparedPublish } from './PlaymeshPublishController';
import type {
  PlaymeshCommittedImportResult,
  PlaymeshPackageProgress,
  PlaymeshPackageUploadError,
} from './PlaymeshPackageUploader';

type PlaymeshPublishState =
  | 'idle'
  | 'exporting'
  | 'uploading'
  | 'fallback-uploading'
  | 'fallback-confirm'
  | 'fallback-error'
  | 'ready'
  | 'uncertain'
  | 'cancelled'
  | 'error';

type PlaymeshUploadMode = 'stream' | 'blob';
type PlaymeshMessageArgument = string | number | boolean | null | void;
type PlaymeshMessageArguments = $ReadOnly<{
  [string]: PlaymeshMessageArgument,
}>;
type PlaymeshResourceProgress = {|
  phase: 'resources',
  completedFiles: number,
  totalFiles: number,
|};
type PlaymeshUiProgress = PlaymeshPackageProgress | PlaymeshResourceProgress;

type PlaymeshUiMessage = $ReadOnly<{|
  key: PlaymeshMessageKey,
  argumentsMap?: PlaymeshMessageArguments,
|}>;

type Props = {
  project: ?gdProject,
  onSaveProject: () => Promise<?FileMetadata>,
  isSavingProject: boolean,
  onClose: () => void,
  ...
};

const PlaymeshPublishDialog = ({
  project,
  onSaveProject,
  isSavingProject,
  onClose,
}: Props): React.Node => {
  const eventsFunctionsExtensionsState = React.useContext(
    EventsFunctionsExtensionsContext
  );
  const [state, setState] = React.useState<PlaymeshPublishState>('idle');
  const [message, setMessage] = React.useState<?PlaymeshUiMessage>(null);
  const [fileCount, setFileCount] = React.useState(0);
  const [progress, setProgress] = React.useState<?PlaymeshUiProgress>(null);
  const { t: playmeshT } = usePlaymeshLocalization();
  const preparedPublishRef = React.useRef<?PlaymeshPreparedPublish>(null);
  const abortControllerRef = React.useRef<?AbortController>(null);
  const operationInFlightRef = React.useRef(false);
  const mountedRef = React.useRef(false);
  const nextOperationTokenRef = React.useRef(0);
  const activeOperationTokenRef = React.useRef<?number>(null);
  const isBusy =
    state === 'exporting' ||
    state === 'uploading' ||
    state === 'fallback-uploading';
  const preparedManifest = preparedPublishRef.current?.manifest;
  const isMultiplayerPublish = !!preparedManifest?.modes?.includes(
    'multiplayer'
  );

  const beginOperation = (): ?number => {
    if (operationInFlightRef.current) return null;
    operationInFlightRef.current = true;
    const token = ++nextOperationTokenRef.current;
    activeOperationTokenRef.current = token;
    return token;
  };
  const isOperationActive = (token: number): boolean =>
    mountedRef.current && activeOperationTokenRef.current === token;
  const finishOperation = (token: number): void => {
    if (activeOperationTokenRef.current !== token) return;
    activeOperationTokenRef.current = null;
    operationInFlightRef.current = false;
  };

  React.useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      activeOperationTokenRef.current = null;
      operationInFlightRef.current = false;
      if (abortControllerRef.current) abortControllerRef.current.abort();
      abortControllerRef.current = null;
    };
  }, []);

  return (
    <I18n>
      {({ i18n }) => {
        const fallbackWarning: PlaymeshUiMessage = {
          key: playmeshMessages.publishStreamFallbackWarning,
        };
        const localizedMessage = message
          ? playmeshT(message.key, message.argumentsMap)
          : null;

        const finishUpload = (
          result: PlaymeshCommittedImportResult,
          operationToken: number
        ): void => {
          if (!isOperationActive(operationToken)) return;
          setState('ready');
          setMessage({
            key: playmeshMessages.publishSuccess,
            argumentsMap: {
              name: (result.project && result.project.name) || 'GDevelop game',
            },
          });
        };

        const handleUploadError = (
          error: ?PlaymeshPackageUploadError,
          mode: PlaymeshUploadMode,
          operationToken: number
        ): void => {
          if (!isOperationActive(operationToken)) return;
          if (!(error && error.code === 'cancelled')) {
            console.warn('Unable to upload Playmesh GDevelop package', error);
          }
          if (error && error.code === 'cancelled') {
            setState(error.stateUncertain ? 'uncertain' : 'cancelled');
            setMessage({
              key: error.stateUncertain
                ? playmeshMessages.publishCancelledUncertain
                : playmeshMessages.publishCancelledClean,
            });
            return;
          }
          if (
            mode === 'stream' &&
            error &&
            error.safeToRetry === true &&
            error.bytesProduced === 0
          ) {
            setState('fallback-confirm');
            setMessage(fallbackWarning);
            return;
          }
          if (error && error.stateUncertain) {
            setState('uncertain');
            setMessage({
              key: playmeshMessages.publishConnectionUncertain,
            });
            return;
          }
          if (mode === 'blob' && error && error.code === 'blob_upload_failed') {
            setState('fallback-error');
            setMessage({ key: playmeshMessages.publishBlobFailed });
            return;
          }
          setState(mode === 'blob' ? 'fallback-error' : 'error');
          setMessage({ key: playmeshMessages.publishFailed });
        };

        const uploadPreparedPackage = async (
          mode: PlaymeshUploadMode,
          continuedOperationToken: ?number = null
        ): Promise<void> => {
          const prepared = preparedPublishRef.current;
          if (!prepared) return;
          const ownsOperation = continuedOperationToken === null;
          const operationToken = ownsOperation
            ? beginOperation()
            : continuedOperationToken;
          if (operationToken === null || operationToken === undefined) return;
          if (!isOperationActive(operationToken)) return;
          const controller = new AbortController();
          abortControllerRef.current = controller;
          setProgress(null);
          setMessage(null);
          setState(mode === 'blob' ? 'fallback-uploading' : 'uploading');
          try {
            const result = await (mode === 'blob'
              ? uploadPlaymeshPackageBlob({
                  producer: prepared.producer,
                  expectedGameId: prepared.gameId,
                  signal: controller.signal,
                  onProgress: (value: PlaymeshPackageProgress) => {
                    if (isOperationActive(operationToken)) setProgress(value);
                  },
                })
              : uploadPlaymeshPackageStream({
                  producer: prepared.producer,
                  expectedGameId: prepared.gameId,
                  signal: controller.signal,
                  onProgress: (value: PlaymeshPackageProgress) => {
                    if (isOperationActive(operationToken)) setProgress(value);
                  },
                }));
            finishUpload(result, operationToken);
          } catch (error) {
            handleUploadError(error, mode, operationToken);
          } finally {
            if (abortControllerRef.current === controller) {
              abortControllerRef.current = null;
            }
            if (ownsOperation) finishOperation(operationToken);
          }
        };

        const preparePublish = async (): Promise<void> => {
          if (!project) return;
          const operationToken = beginOperation();
          if (operationToken === null || operationToken === undefined) return;
          const controller = new AbortController();
          abortControllerRef.current = controller;
          preparedPublishRef.current = null;
          setState('exporting');
          setMessage(null);
          setProgress(null);
          try {
            const saved = await onSaveProject();
            if (!isOperationActive(operationToken)) return;
            if (!saved || !saved.gameId || controller.signal.aborted) {
              if (controller.signal.aborted) {
                setState('cancelled');
                setMessage({
                  key: playmeshMessages.publishCancelledBeforeUpload,
                });
              } else {
                setState('idle');
                setMessage({ key: playmeshMessages.publishSaveLocalFirst });
              }
              return;
            }
            const prepared = await createPlaymeshGDevelopPublishFileMap({
              project,
              gameId: saved.gameId,
              i18n,
              eventsFunctionsExtensionsState,
              signal: controller.signal,
              onProgress: value => {
                if (!isOperationActive(operationToken)) return;
                setProgress({
                  phase: 'resources',
                  completedFiles: value.count,
                  totalFiles: value.total,
                });
              },
            });
            if (!isOperationActive(operationToken)) return;
            if (controller.signal.aborted) {
              setState('cancelled');
              setMessage({
                key: playmeshMessages.publishCancelledBeforeUpload,
              });
              return;
            }
            preparedPublishRef.current = prepared;
            setFileCount(prepared.fileMap.size);
            window.dispatchEvent(
              new CustomEvent('playmesh-gdevelop-publish-file-map-ready', {
                detail: {
                  gameId: prepared.gameId,
                  manifest: prepared.manifest,
                  producer: prepared.producer,
                },
              })
            );
            if (!supportsPlaymeshStreamingUpload()) {
              abortControllerRef.current = null;
              setState('fallback-confirm');
              setMessage(fallbackWarning);
              return;
            }
            setState('idle');
            abortControllerRef.current = null;
            await uploadPreparedPackage('stream', operationToken);
          } catch (error) {
            if (!isOperationActive(operationToken)) return;
            if (error && error.name === 'AbortError') {
              setState('cancelled');
              setMessage({
                key: playmeshMessages.publishCancelledBeforeUpload,
              });
            } else {
              console.warn(
                'Unable to prepare Playmesh GDevelop publish',
                error
              );
              setState('error');
              setMessage({
                key:
                  error instanceof PlaymeshPublishError &&
                  error.code === 'project_config_blocks_multiplayer_publish'
                    ? playmeshMessages.projectConfigPublishBlocked
                    : playmeshMessages.publishPrepareFailed,
              });
            }
          } finally {
            if (abortControllerRef.current === controller) {
              abortControllerRef.current = null;
            }
            finishOperation(operationToken);
          }
        };

        const cancelPublish = (): void => {
          if (abortControllerRef.current) abortControllerRef.current.abort();
        };

        const primaryAction =
          state === 'fallback-confirm' || state === 'fallback-error'
            ? () => uploadPreparedPackage('blob')
            : preparePublish;
        const primaryLabel =
          state === 'exporting'
            ? playmeshT(playmeshMessages.publishExporting)
            : state === 'uploading'
            ? playmeshT(playmeshMessages.publishStreaming)
            : state === 'fallback-uploading'
            ? playmeshT(playmeshMessages.publishMemoryUploading)
            : state === 'fallback-confirm'
            ? playmeshT(playmeshMessages.publishConfirmMemory)
            : state === 'fallback-error'
            ? playmeshT(playmeshMessages.publishRetryMemory)
            : state === 'ready'
            ? playmeshT(playmeshMessages.publishPublished)
            : playmeshT(playmeshMessages.publishLocal);

        return (
          <Dialog
            id="export-dialog"
            maxWidth="sm"
            title={playmeshT(playmeshMessages.publishTitle)}
            actions={[
              <FlatButton
                key="close-or-cancel"
                label={
                  isBusy
                    ? playmeshT(playmeshMessages.publishCancel)
                    : playmeshT(playmeshMessages.publishClose)
                }
                primary={false}
                onClick={isBusy ? cancelPublish : onClose}
              />,
              <RaisedButton
                key="publish"
                label={primaryLabel}
                primary
                disabled={
                  !project ||
                  isSavingProject ||
                  isBusy ||
                  state === 'ready' ||
                  state === 'uncertain'
                }
                onClick={primaryAction}
              />,
            ]}
            onRequestClose={isBusy ? () => {} : onClose}
            open
          >
            <ColumnStackLayout noMargin useLargeSpacer>
              <Text size="block-title">
                {playmeshT(playmeshMessages.publishDestination)}
              </Text>
              <Text>{playmeshT(playmeshMessages.publishDescription)}</Text>
              {isMultiplayerPublish && (
                <AlertMessage kind="info">
                  {playmeshT(playmeshMessages.multiplayerCompatibility)}
                </AlertMessage>
              )}
              {progress && 'totalFiles' in progress && progress.totalFiles > 0 && (
                <Text>
                  {progress.phase === 'resources'
                    ? playmeshT(playmeshMessages.publishResourcesProgress, {
                        completed: progress.completedFiles || 0,
                        total: progress.totalFiles,
                      })
                    : playmeshT(playmeshMessages.publishArchiveProgress, {
                        completed: progress.completedFiles || 0,
                        total: progress.totalFiles,
                      })}
                </Text>
              )}
              {progress &&
                'bytesProduced' in progress &&
                progress.bytesProduced > 0 && (
                  <Text>
                    {playmeshT(playmeshMessages.publishBytesProgress, {
                      kib: Math.ceil(progress.bytesProduced / 1024),
                    })}
                  </Text>
                )}
              {localizedMessage && (
                <AlertMessage
                  kind={
                    state === 'ready'
                      ? 'valid'
                      : state === 'fallback-confirm' || state === 'uncertain'
                      ? 'warning'
                      : state === 'cancelled'
                      ? 'info'
                      : 'error'
                  }
                >
                  {localizedMessage}
                  {state === 'ready'
                    ? ` ${playmeshT(playmeshMessages.publishFileCount, {
                        count: fileCount,
                      })}`
                    : ''}
                </AlertMessage>
              )}
              <AlertMessage kind="info">
                {playmeshT(playmeshMessages.publishStreamingInfo)}
              </AlertMessage>
            </ColumnStackLayout>
          </Dialog>
        );
      }}
    </I18n>
  );
};

export default PlaymeshPublishDialog;
