// @flow

import * as React from 'react';
import { Trans } from '@lingui/macro';
import { type I18n as I18nType } from '@lingui/core';
import AlertMessage from '../UI/AlertMessage';
import CircularProgress from '../UI/CircularProgress';
import Dialog from '../UI/Dialog';
import FlatButton from '../UI/FlatButton';
import RaisedButton from '../UI/RaisedButton';
import { SimpleTextField } from '../UI/SimpleTextField';
import { showErrorBox } from '../UI/Messages/MessageBox';
import {
  loadPlaymeshExamplesIndex,
  getPlaymeshExampleLicensePreviewStatus,
  inspectPlaymeshExampleLicense,
  resetPlaymeshCatalogForRetry,
} from '../PlaymeshCatalog/PlaymeshCatalogSource';
import type {
  PlaymeshExampleHeader,
  PlaymeshExamplesIndex,
  PlaymeshVerifiedExampleLicense,
} from '../PlaymeshCatalog/PlaymeshCatalogSource';
import {
  importPlaymeshExample,
  normalizePlaymeshExampleImportError,
  reportPlaymeshExampleImportFailure,
  type PlaymeshExampleImportError,
} from '../PlaymeshCatalog/PlaymeshExampleImporter';
import type { PlaymeshExampleImportProgress } from '../PlaymeshCatalog/PlaymeshExampleImporter';
import { presentPlaymeshExternalDownloadFailure } from '../PlaymeshCatalog/PlaymeshExternalDownloadErrorPresenter';
import { usePlaymeshLocalization } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';
import type { PlaymeshMessageKey } from '../PlaymeshLocalization/PlaymeshMessageKeys';
import type { PlaymeshMessageArguments } from '../PlaymeshLocalization/PlaymeshLocalizationSession';
import type {
  FileMetadata,
  FileMetadataAndStorageProviderName,
} from '../ProjectsStorage';
import classes from './PlaymeshNewProjectCatalog.module.css';

type PlaymeshTranslate = (
  key: PlaymeshMessageKey,
  argumentsMap?: PlaymeshMessageArguments
) => string;

type ImportProgress = {|
  completed: number,
  total: ?number,
|};

type ImportFailure = {|
  error: PlaymeshExampleImportError,
  header: PlaymeshExampleHeader,
  licenseEvidenceKey?: string,
|};

type LicenseDialogState = {|
  header: PlaymeshExampleHeader,
  presentation: PlaymeshExamplePresentation,
  intent: 'inspect' | 'import',
|};

type VisibleLicenseStatus =
  | 'open'
  | 'pending'
  | 'non-open'
  | 'unknown'
  | 'conflict';

export type PlaymeshExamplePresentation = {|
  name: string,
  shortDescription: string,
  description: string,
  license: string,
  contributors: string,
  licenseStatus: VisibleLicenseStatus,
|};

const GENERATED_SHORT_DESCRIPTION =
  'GDevelop 官方示例，导入时按需下载并在本机校验。';
const GENERATED_DESCRIPTION =
  '项目 JSON 会先下载并校验；仅下载其中实际引用的安全相对资源。';

const translateOfficialText = (i18n: I18nType, value: string): string => {
  if (!value) return '';
  try {
    const translated = i18n._(value);
    return typeof translated === 'string' && translated.trim()
      ? translated
      : value;
  } catch (_) {
    return value;
  }
};

export const resolvePlaymeshExamplePresentation = ({
  header,
  i18n,
  playmeshT,
}: {|
  header: PlaymeshExampleHeader,
  i18n: I18nType,
  playmeshT: PlaymeshTranslate,
|}): PlaymeshExamplePresentation => ({
  // GDevelop's own catalog translations have priority whenever the locked
  // metadata text is already present in the active official message catalog.
  name: translateOfficialText(i18n, header.name),
  shortDescription:
    header.shortDescription === GENERATED_SHORT_DESCRIPTION
      ? playmeshT(playmeshMessages.examplesPinnedSource)
      : translateOfficialText(i18n, header.shortDescription),
  description:
    header.description === GENERATED_DESCRIPTION
      ? playmeshT(playmeshMessages.examplesReferencedDownload)
      : translateOfficialText(i18n, header.description),
  license: translateOfficialText(i18n, header.license.defaultName),
  contributors: header.authors.filter(Boolean).join(', '),
  licenseStatus: getPlaymeshExampleLicensePreviewStatus(header),
});

const formatBytes = (bytes: number, playmeshT: PlaymeshTranslate): string => {
  if (!Number.isFinite(bytes) || bytes < 0) {
    return playmeshT(playmeshMessages.examplesReferencedDownload);
  }
  if (bytes < 1024 * 1024) return `${Math.ceil(bytes / 1024)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
};

const getLicenseStatusLabel = (
  status: VisibleLicenseStatus,
  playmeshT: PlaymeshTranslate
): string => {
  switch (status) {
    case 'open':
      return playmeshT(playmeshMessages.examplesLicenseOpen);
    case 'pending':
      return playmeshT(playmeshMessages.examplesLicensePending);
    case 'non-open':
      return playmeshT(playmeshMessages.examplesLicenseNonOpen);
    case 'conflict':
      return playmeshT(playmeshMessages.examplesLicenseConflict);
    default:
      return playmeshT(playmeshMessages.examplesLicenseUnknown);
  }
};

const getLicenseStatusClassName = (
  status: VisibleLicenseStatus
): string => {
  if (status === 'open') return classes.licenseStatusOpen;
  if (status === 'pending') return classes.licenseStatusPending;
  return classes.licenseStatusWarning;
};

const getLicenseStatusDescription = (
  status: VisibleLicenseStatus,
  playmeshT: PlaymeshTranslate
): string => {
  switch (status) {
    case 'open':
      return playmeshT(playmeshMessages.examplesLicenseOpenDescription);
    case 'non-open':
      return playmeshT(playmeshMessages.examplesLicenseNonOpenDescription);
    case 'conflict':
      return playmeshT(playmeshMessages.examplesLicenseConflictDescription);
    case 'unknown':
      return playmeshT(playmeshMessages.examplesLicenseUnknownDescription);
    default:
      return playmeshT(playmeshMessages.examplesLicensePendingDescription);
  }
};

type ThumbnailProps = {|
  header: PlaymeshExampleHeader,
|};

export const PlaymeshExampleThumbnail = ({
  header,
}: ThumbnailProps): React.Node => {
  const previewUrl = header.preview ? header.preview.url : '';
  const [failedUrl, setFailedUrl] = React.useState<?string>(null);
  const canShowImage = !!previewUrl && failedUrl !== previewUrl;

  return (
    <div className={classes.thumbnail}>
      {canShowImage ? (
        <img
          src={previewUrl}
          alt=""
          loading="lazy"
          decoding="async"
          onError={() => setFailedUrl(previewUrl)}
        />
      ) : (
        <div className={classes.thumbnailFallback} aria-hidden="true">
          <span>{header.name.trim().slice(0, 1).toLocaleUpperCase() || 'G'}</span>
        </div>
      )}
    </div>
  );
};

type ExampleCardProps = {|
  header: PlaymeshExampleHeader,
  presentation: PlaymeshExamplePresentation,
  disabled: boolean,
  progress: ?ImportProgress,
  onImport: () => void | Promise<void>,
  onViewNotice: () => void,
  playmeshT: PlaymeshTranslate,
|};

const ExampleCard = ({
  header,
  presentation,
  disabled,
  progress,
  onImport,
  onViewNotice,
  playmeshT,
}: ExampleCardProps): React.Node => (
  <article className={classes.card}>
    <PlaymeshExampleThumbnail header={header} />
    <div className={classes.cardBody}>
      <h3 className={classes.cardTitle}>{presentation.name}</h3>
      <p className={classes.cardDescription} title={presentation.description}>
        {presentation.shortDescription || presentation.description}
      </p>
      <div className={classes.cardMeta}>
        {playmeshT(playmeshMessages.examplesRowMeta, {
          count: header.declaredFileCount,
          size: formatBytes(header.declaredRepositoryBytes, playmeshT),
        })}
      </div>
      <dl className={classes.provenance}>
        <div>
          <dt>{playmeshT(playmeshMessages.examplesContributors)}</dt>
          <dd>
            {presentation.contributors ||
              playmeshT(playmeshMessages.examplesContributorsUnknown)}
          </dd>
        </div>
        <div>
          <dt>{playmeshT(playmeshMessages.examplesCopyright)}</dt>
          <dd>{playmeshT(playmeshMessages.examplesRightsNotice)}</dd>
        </div>
        <div>
          <dt>{playmeshT(playmeshMessages.examplesLicense)}</dt>
          <dd>
            <span
              className={`${classes.licenseStatus} ${getLicenseStatusClassName(
                presentation.licenseStatus
              )}`}
            >
              {getLicenseStatusLabel(presentation.licenseStatus, playmeshT)}
            </span>{' '}
            {presentation.license}
          </dd>
        </div>
      </dl>
      <div className={classes.cardActions}>
        {progress ? <CircularProgress size={20} /> : null}
        <FlatButton
          label={playmeshT(playmeshMessages.examplesViewNotice)}
          onClick={onViewNotice}
          disabled={disabled}
        />
        <RaisedButton
          primary
          label={
            progress
              ? playmeshT(playmeshMessages.examplesImporting)
              : playmeshT(playmeshMessages.examplesUse)
          }
          onClick={onImport}
          disabled={disabled}
        />
        {progress ? (
          <span className={classes.progressText}>
            {progress.total == null
              ? progress.completed
              : `${progress.completed} / ${progress.total}`}
          </span>
        ) : null}
      </div>
    </div>
  </article>
);

type Props = {|
  i18n: I18nType,
  disabled?: boolean,
  onOpenProject: (
    file: FileMetadataAndStorageProviderName
  ) => Promise<void>,
  onImported: () => void,
  onImportingChange: boolean => void,
|};

const PlaymeshNewProjectCatalog = ({
  i18n,
  disabled,
  onOpenProject,
  onImported,
  onImportingChange,
}: Props): React.Node => {
  const [index, setIndex] = React.useState<?PlaymeshExamplesIndex>(null);
  const [searchText, setSearchText] = React.useState<string>('');
  const [loadError, setLoadError] = React.useState<boolean>(false);
  const [importFailure, setImportFailure] = React.useState<?ImportFailure>(
    null
  );
  const [reloadKey, setReloadKey] = React.useState<number>(0);
  const [importingId, setImportingId] = React.useState<?string>(null);
  const [progress, setProgress] = React.useState<?ImportProgress>(null);
  const importController = React.useRef<?AbortController>(null);
  const licenseController = React.useRef<?AbortController>(null);
  const [licenseDialog, setLicenseDialog] = React.useState<?LicenseDialogState>(
    null
  );
  const [licenseInspection, setLicenseInspection] = React.useState<
    ?PlaymeshVerifiedExampleLicense
  >(null);
  const [licenseInspectionsById, setLicenseInspectionsById] = React.useState<
    Map<string, PlaymeshVerifiedExampleLicense>
  >(new Map());
  const [licenseLoading, setLicenseLoading] = React.useState<boolean>(false);
  const [licenseError, setLicenseError] = React.useState<boolean>(false);
  const [licenseAcknowledged, setLicenseAcknowledged] = React.useState<boolean>(
    false
  );
  const [catalogNoticeOpen, setCatalogNoticeOpen] = React.useState<boolean>(
    false
  );
  const { t: playmeshT, localeId } = usePlaymeshLocalization();

  React.useEffect(
    () => {
      const controller = new AbortController();
      setIndex(null);
      setLoadError(false);
      loadPlaymeshExamplesIndex({
        signal: controller.signal,
        force: reloadKey > 0,
      })
        .then((loadedIndex: PlaymeshExamplesIndex) => setIndex(loadedIndex))
        .catch((_loadError: mixed) => {
          if (!controller.signal.aborted) setLoadError(true);
        });
      return () => controller.abort();
    },
    [reloadKey]
  );

  React.useEffect(
    () => () => {
      if (importController.current) importController.current.abort();
      if (licenseController.current) licenseController.current.abort();
    },
    []
  );

  const presentations = React.useMemo(
    () => {
      const result: Map<string, PlaymeshExamplePresentation> = new Map();
      if (!index) return result;
      index.headers.forEach((header: PlaymeshExampleHeader) => {
        result.set(
          header.id,
          resolvePlaymeshExamplePresentation({ header, i18n, playmeshT })
        );
      });
      return result;
    },
    // localeId makes the presentation follow a temporary GDevelop language
    // switch even when the stable translation function identity is unchanged.
    [i18n, index, localeId, playmeshT]
  );

  const visibleHeaders = React.useMemo<Array<PlaymeshExampleHeader>>(
    () => {
      if (!index) return [];
      const query = searchText.trim().toLocaleLowerCase(localeId);
      if (!query) return index.headers;
      return index.headers.filter((header: PlaymeshExampleHeader) => {
        const presentation = presentations.get(header.id);
        return [
          presentation ? presentation.name : header.name,
          presentation ? presentation.description : header.description,
          presentation ? presentation.contributors : header.authors.join(' '),
          presentation ? presentation.license : header.license.defaultName,
          header.project.repository,
          ...(header.tags || []),
        ]
          .join(' ')
          .toLocaleLowerCase(localeId)
          .includes(query);
      });
    },
    [index, localeId, presentations, searchText]
  );

  const closeLicenseDialog = (): void => {
    if (licenseController.current) licenseController.current.abort();
    licenseController.current = null;
    setLicenseDialog(null);
    setLicenseInspection(null);
    setLicenseLoading(false);
    setLicenseError(false);
    setLicenseAcknowledged(false);
  };

  const openLicenseDialog = (
    header: PlaymeshExampleHeader,
    intent: 'inspect' | 'import'
  ): void => {
    if (disabled || importingId) return;
    if (licenseController.current) licenseController.current.abort();
    const controller = new AbortController();
    licenseController.current = controller;
    const presentation =
      presentations.get(header.id) ||
      resolvePlaymeshExamplePresentation({ header, i18n, playmeshT });
    setLicenseDialog({ header, presentation, intent });
    setLicenseInspection(null);
    setLicenseLoading(true);
    setLicenseError(false);
    setLicenseAcknowledged(false);
    inspectPlaymeshExampleLicense({ header, signal: controller.signal })
      .then((inspection: PlaymeshVerifiedExampleLicense) => {
        if (controller.signal.aborted) return;
        setLicenseInspection(inspection);
        setLicenseInspectionsById(previous => {
          const next = new Map(previous);
          next.set(header.id, inspection);
          return next;
        });
        setLicenseLoading(false);
      })
      .catch(() => {
        if (controller.signal.aborted) return;
        setLicenseError(true);
        setLicenseLoading(false);
      });
  };

  const retry = (): void => {
    resetPlaymeshCatalogForRetry('examples');
    setReloadKey((value: number): number => value + 1);
  };

  const importExample = async (
    header: PlaymeshExampleHeader,
    licenseEvidenceKey?: string
  ): Promise<void> => {
    if (disabled || importingId) return;
    const controller = new AbortController();
    importController.current = controller;
    setImportFailure(null);
    setImportingId(header.id);
    setProgress({ completed: 0, total: null });
    onImportingChange(true);
    let fileMetadata: FileMetadata;
    try {
      fileMetadata = await importPlaymeshExample({
        header,
        signal: controller.signal,
        licenseEvidenceKey,
        onProgress: (nextProgress: PlaymeshExampleImportProgress): void =>
          setProgress({
            completed: nextProgress.completed,
            total: nextProgress.total,
          }),
      });
    } catch (rawError) {
      if (!controller.signal.aborted) {
        const error = normalizePlaymeshExampleImportError(
          rawError,
          'project_open',
          'gdevelop.project.open'
        );
        reportPlaymeshExampleImportFailure(error);
        if (error.targetUrl) {
          presentPlaymeshExternalDownloadFailure({
            rawError: error,
            stage: error.stage,
            operation: error.operation,
            errorId: 'playmesh-example-download-error',
          });
        } else {
          const diagnostics =
            `stage=${error.stage} operation=${error.operation} ` +
            `status=${error.status || 0} reason=${
              error.reason || error.code
            } code=${error.code} requestId=${
              error.requestId || 'unavailable'
            }`;
          showErrorBox({
            message: `${playmeshT(
              playmeshMessages.projectImportFailed
            )}\n${diagnostics}`,
            rawError: new Error(
              `${error.code}:${error.reason || error.code}:${
                error.requestId || 'unavailable'
              }`
            ),
            errorId: 'playmesh-example-import-error',
            doNotReport: true,
          });
        }
        setImportFailure({ error, header, licenseEvidenceKey });
      }
      importController.current = null;
      setImportingId(null);
      setProgress(null);
      onImportingChange(false);
      return;
    }
    // The Playmesh import boundary is complete. Clear its progress state
    // before handing the verified FileMetadata to the official project opener;
    // opener errors retain their own type, message and handling.
    importController.current = null;
    setImportingId(null);
    setProgress(null);
    onImportingChange(false);
    await onOpenProject({
      fileMetadata,
      storageProviderName: 'PlaymeshLocal',
    });
    onImported();
  };

  const importReviewedExample = (): void => {
    if (!licenseDialog || !licenseInspection || licenseLoading) return;
    const requiresAcknowledgement = licenseInspection.status !== 'open';
    if (requiresAcknowledgement && !licenseAcknowledged) return;
    const header = licenseDialog.header;
    const evidenceKey = licenseInspection.evidenceKey;
    closeLicenseDialog();
    importExample(header, evidenceKey);
  };

  const reviewedLicenseStatus: VisibleLicenseStatus = licenseInspection
    ? licenseInspection.status
    : licenseError
    ? 'unknown'
    : 'pending';
  const reviewedLicenseRequiresAcknowledgement =
    !!licenseDialog &&
    licenseDialog.intent === 'import' &&
    !!licenseInspection &&
    licenseInspection.status !== 'open';

  return (
    <section className={classes.root}>
      <div className={classes.headingRow}>
        <h2 className={classes.heading}>
          {playmeshT(playmeshMessages.homeOfficialExamples)}
        </h2>
        <div className={classes.headingActions}>
          <FlatButton
            label={playmeshT(playmeshMessages.examplesCatalogNotice)}
            onClick={() => setCatalogNoticeOpen(true)}
          />
          {index ? (
            <span className={classes.resultCount}>
              {visibleHeaders.length} / {index.headers.length}
            </span>
          ) : null}
        </div>
      </div>
      <SimpleTextField
        id="playmesh-new-project-example-search"
        type="text"
        disabled={!!disabled || !!importingId}
        value={searchText}
        hint={playmeshT(playmeshMessages.examplesSearch)}
        directlyStoreValueChangesWhileEditing
        onChange={(value: string) => setSearchText(value)}
      />
      {loadError ? (
        <div className={classes.catalogStatus}>
          <AlertMessage kind="warning">
            {playmeshT(playmeshMessages.examplesUnavailable)}
          </AlertMessage>
          <RaisedButton
            label={<Trans id="Retry" defaults="Retry" />}
            onClick={retry}
            disabled={!!disabled || !!importingId}
          />
        </div>
      ) : !index ? (
        <div className={classes.catalogStatus}>
          <CircularProgress size={24} />
          <span>{playmeshT(playmeshMessages.examplesLoading)}</span>
        </div>
      ) : null}
      {importFailure ? (
        <div className={classes.importFailure}>
          <AlertMessage kind="error">
            <div>{importFailure.error.message}</div>
            <code className={classes.diagnostics}>
              {`stage=${importFailure.error.stage} operation=${
                importFailure.error.operation
              } status=${importFailure.error.status || 0} code=${
                importFailure.error.code
              } requestId=${importFailure.error.requestId || 'unavailable'}`}
            </code>
          </AlertMessage>
          <RaisedButton
            label={<Trans id="Retry" defaults="Retry" />}
            onClick={() =>
              importExample(
                importFailure.header,
                importFailure.licenseEvidenceKey
              )
            }
            disabled={!!disabled || !!importingId}
          />
        </div>
      ) : null}
      {index && visibleHeaders.length ? (
        <div
          className={classes.grid}
          aria-label={playmeshT(playmeshMessages.examplesListLabel)}
        >
          {visibleHeaders.map((header: PlaymeshExampleHeader) => {
            const basePresentation =
              presentations.get(header.id) ||
              resolvePlaymeshExamplePresentation({
                header,
                i18n,
                playmeshT,
              });
            const inspection = licenseInspectionsById.get(header.id);
            return (
              <ExampleCard
                key={header.id}
                header={header}
                presentation={
                  inspection
                    ? {
                        ...basePresentation,
                        license: inspection.name,
                        licenseStatus: inspection.status,
                      }
                    : basePresentation
                }
                disabled={!!disabled || !!importingId}
                progress={importingId === header.id ? progress : null}
                onImport={() => openLicenseDialog(header, 'import')}
                onViewNotice={() => openLicenseDialog(header, 'inspect')}
                playmeshT={playmeshT}
              />
            );
          })}
        </div>
      ) : index ? (
        <div className={classes.catalogStatus}>
          {playmeshT(playmeshMessages.examplesNoMatch)}
        </div>
      ) : null}
      {catalogNoticeOpen && (
        <Dialog
          open
          title={playmeshT(playmeshMessages.examplesCatalogNoticeTitle)}
          actions={[
            <FlatButton
              key="close"
              label={playmeshT(playmeshMessages.examplesClose)}
              onClick={() => setCatalogNoticeOpen(false)}
            />,
          ]}
          onRequestClose={() => setCatalogNoticeOpen(false)}
          maxWidth="sm"
        >
          <div className={classes.noticeDialog}>
            <p>{playmeshT(playmeshMessages.examplesCatalogNoticeBody)}</p>
            <dl className={classes.noticeFacts}>
              <div>
                <dt>{playmeshT(playmeshMessages.examplesSource)}</dt>
                <dd>
                  {index
                    ? index.source.repository
                    : 'GDevelopApp/GDevelop-examples'}
                </dd>
              </div>
              {index ? (
                <div>
                  <dt>{playmeshT(playmeshMessages.examplesSourceRevision)}</dt>
                  <dd>
                    <code>{index.source.commit}</code>
                  </dd>
                </div>
              ) : null}
              <div>
                <dt>{playmeshT(playmeshMessages.examplesCopyright)}</dt>
                <dd>{playmeshT(playmeshMessages.examplesRightsNotice)}</dd>
              </div>
            </dl>
            <AlertMessage kind="info">
              {playmeshT(playmeshMessages.examplesCatalogPolicyHint)}
            </AlertMessage>
          </div>
        </Dialog>
      )}
      {licenseDialog && (
        <Dialog
          open
          title={playmeshT(playmeshMessages.examplesLicenseDialogTitle, {
            name: licenseDialog.presentation.name,
          })}
          actions={[
            <FlatButton
              key="close"
              label={playmeshT(playmeshMessages.examplesClose)}
              onClick={closeLicenseDialog}
            />,
            ...(licenseError
              ? [
                  <FlatButton
                    key="retry"
                    label={playmeshT(playmeshMessages.examplesLicenseRetry)}
                    onClick={() =>
                      openLicenseDialog(
                        licenseDialog.header,
                        licenseDialog.intent
                      )
                    }
                  />,
                ]
              : []),
            ...(licenseDialog.intent === 'import'
              ? [
                  <RaisedButton
                    key="import"
                    primary
                    label={playmeshT(
                      playmeshMessages.examplesUseAfterReview
                    )}
                    onClick={importReviewedExample}
                    disabled={
                      licenseLoading ||
                      !licenseInspection ||
                      (reviewedLicenseRequiresAcknowledgement &&
                        !licenseAcknowledged)
                    }
                  />,
                ]
              : []),
          ]}
          onRequestClose={closeLicenseDialog}
          maxWidth="md"
        >
          <div className={classes.noticeDialog}>
            <div className={classes.licenseDialogHeading}>
              <span
                className={`${classes.licenseStatus} ${getLicenseStatusClassName(
                  reviewedLicenseStatus
                )}`}
              >
                {getLicenseStatusLabel(reviewedLicenseStatus, playmeshT)}
              </span>
              <strong>
                {licenseInspection
                  ? licenseInspection.name
                  : licenseDialog.presentation.license}
              </strong>
            </div>
            <p>
              {getLicenseStatusDescription(
                reviewedLicenseStatus,
                playmeshT
              )}
            </p>
            {licenseLoading ? (
              <div className={classes.licenseLoading} role="status">
                <CircularProgress size={20} />
                <span>
                  {playmeshT(playmeshMessages.examplesLicenseChecking)}
                </span>
              </div>
            ) : null}
            {licenseError ? (
              <AlertMessage kind="warning">
                {playmeshT(playmeshMessages.examplesLicenseCheckFailed)}
              </AlertMessage>
            ) : null}
            <dl className={classes.noticeFacts}>
              <div>
                <dt>{playmeshT(playmeshMessages.examplesContributors)}</dt>
                <dd>
                  {licenseDialog.presentation.contributors ||
                    playmeshT(
                      playmeshMessages.examplesContributorsUnknown
                    )}
                </dd>
              </div>
              <div>
                <dt>{playmeshT(playmeshMessages.examplesCopyright)}</dt>
                <dd>{playmeshT(playmeshMessages.examplesRightsNotice)}</dd>
              </div>
              <div>
                <dt>{playmeshT(playmeshMessages.examplesSource)}</dt>
                <dd>
                  {licenseDialog.header.project.repository}
                  <br />
                  <code>{licenseDialog.header.project.commit}</code>
                </dd>
              </div>
              <div>
                <dt>{playmeshT(playmeshMessages.examplesLicenseSource)}</dt>
                <dd className={classes.sourceUrl}>
                  {licenseInspection
                    ? licenseInspection.sourceUrl
                    : licenseDialog.header.license.defaultSourceUrl}
                </dd>
              </div>
            </dl>
            {licenseInspection && licenseInspection.documents.length ? (
              <div className={classes.evidenceList}>
                <h4>{playmeshT(playmeshMessages.examplesEvidence)}</h4>
                {licenseInspection.documents.map(document => (
                  <div className={classes.evidenceRow} key={document.path}>
                    <code>{document.path}</code>
                    <div>
                      <span>
                        {document.detectedLicense ||
                          (document.detectedRestrictions.length
                            ? document.detectedRestrictions.join(', ')
                            : playmeshT(
                                document.hasUnresolvedPolicyClaim
                                  ? playmeshMessages.examplesEvidenceUnresolved
                                  : playmeshMessages.examplesEvidenceNeutral
                              ))}
                      </span>
                      {document.copyrightNotices.map(notice => (
                        <small
                          className={classes.copyrightNotice}
                          key={notice}
                        >
                          {notice}
                        </small>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            ) : licenseInspection ? (
              <p className={classes.secondaryText}>
                {playmeshT(playmeshMessages.examplesRepositoryDefaultEvidence)}
              </p>
            ) : null}
            {reviewedLicenseRequiresAcknowledgement ? (
              <label className={classes.acknowledgement}>
                <input
                  type="checkbox"
                  checked={licenseAcknowledged}
                  onChange={event =>
                    setLicenseAcknowledged(event.currentTarget.checked)
                  }
                />
                <span>
                  {playmeshT(playmeshMessages.examplesAcknowledgeNotice)}
                </span>
              </label>
            ) : null}
          </div>
        </Dialog>
      )}
    </section>
  );
};

export default PlaymeshNewProjectCatalog;
