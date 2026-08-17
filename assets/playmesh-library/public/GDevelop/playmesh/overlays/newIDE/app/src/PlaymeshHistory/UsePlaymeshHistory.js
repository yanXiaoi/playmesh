// @flow

import * as React from "react";
import Drawer from "@material-ui/core/Drawer";
import HistoryIcon from "../UI/CustomSvgIcons/History";
import DrawerTopBar from "../UI/DrawerTopBar";
import AlertMessage from "../UI/AlertMessage";
import FlatButton from "../UI/FlatButton";
import RaisedButton from "../UI/RaisedButton";
import Paper from "../UI/Paper";
import Text from "../UI/Text";
import PlaceholderLoader from "../UI/PlaceholderLoader";
import PlaceholderError from "../UI/PlaceholderError";
import { Column, Line } from "../UI/Grid";
import GDevelopThemeContext from "../UI/Theme/GDevelopThemeContext";
import { useResponsiveWindowSize } from "../UI/Responsive/ResponsiveWindowMeasurer";
import {
  getPlaymeshHistoryDiff,
  listPlaymeshHistory
} from "./PlaymeshHistoryClient";
import { buildPlaymeshHistoryDiffSummary } from "./PlaymeshHistoryDiffSummary";
import { buildPlaymeshHistoryDiffModel } from "./PlaymeshHistoryDiffModel";
import PlaymeshHistoryDiffDialog from "./PlaymeshHistoryDiffDialog";
import type {
  PlaymeshHistoryDiff,
  PlaymeshHistoryReason,
  PlaymeshHistoryVersion
} from "./PlaymeshHistoryClient";
import { restorePlaymeshHistoryToLocalStore } from "./PlaymeshHistoryRestoreCoordinator";
import { usePlaymeshLocalization } from "../PlaymeshLocalization/PlaymeshLocalizationProvider";
import { playmeshMessages } from "../PlaymeshLocalization/PlaymeshMessageKeys";
import type { PlaymeshMessageKey } from "../PlaymeshLocalization/PlaymeshMessageKeys";
import type { PlaymeshMessageArguments } from "../PlaymeshLocalization/PlaymeshLocalizationSession";
import type { FileMetadata, StorageProvider } from "../ProjectsStorage";
import type { MessageDescriptor } from "../Utils/i18n/MessageDescriptor.flow";
import type { ExpandedCloudProjectVersion } from "../Utils/GDevelopServices/Project";
import type { OpenedVersionStatus } from "../VersionHistory";

type PlaymeshTranslate = (
  key: PlaymeshMessageKey,
  argumentsMap?: PlaymeshMessageArguments
) => string;

type Props = {|
  getStorageProvider: () => StorageProvider,
  fileMetadata: ?FileMetadata,
  isSavingProject: boolean,
  project: ?gdProject,
  onOpenCloudProjectOnSpecificVersion: ({|
    fileMetadata: FileMetadata,
    versionId: string,
    ignoreUnsavedChanges: boolean,
    ignoreAutoSave: boolean,
    openingMessage: MessageDescriptor
  |}) => Promise<void>
|};

type UsePlaymeshHistoryReturn = {|
  checkedOutVersionStatus: ?OpenedVersionStatus,
  openVersionHistoryPanel: () => void,
  renderVersionHistoryPanel: () => React.Node,
  onQuitVersionHistory: () => Promise<void>,
  onCheckoutVersion: (
    version: ExpandedCloudProjectVersion,
    options?: {| dontSaveCheckedOutVersionStatus?: boolean |}
  ) => Promise<boolean>,
  getOrLoadProjectVersion: (
    versionId: string
  ) => Promise<ExpandedCloudProjectVersion>
|};

type HistoryStatusDetail = {|
  gameId: string,
  state: string,
  error: mixed
|};

type MixedRecord = { +[string]: mixed };

const asMixedRecord = (value: mixed): ?MixedRecord => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return (value: MixedRecord);
};

const readHistoryStatusDetail = (event: Event): ?HistoryStatusDetail => {
  if (!(event instanceof CustomEvent)) return null;
  const detail = asMixedRecord(event.detail);
  if (!detail || typeof detail.gameId !== "string") return null;
  return {
    gameId: detail.gameId,
    state: typeof detail.state === "string" ? detail.state : "",
    error: detail.error
  };
};

const styles = {
  drawerContent: {
    width: "min(720px, 72vw)",
    maxWidth: "100vw",
    height: "100%",
    overflowX: "hidden",
    display: "flex",
    flexDirection: "column"
  },
  scrollArea: {
    overflowY: "auto",
    flex: 1
  },
  drawerTitle: {
    display: "inline-flex",
    alignItems: "center",
    minWidth: 0
  },
  drawerTitleIcon: {
    display: "inline-flex",
    alignItems: "center",
    marginRight: 8,
    flexShrink: 0
  },
  revisionCard: {
    position: "relative",
    margin: "0 12px 10px 20px",
    padding: "12px 14px",
    borderLeft: "3px solid transparent"
  },
  timeline: {
    position: "relative",
    paddingTop: 12,
    paddingBottom: 4
  },
  timelineRail: {
    position: "absolute",
    top: 18,
    bottom: 18,
    left: 12,
    width: 1
  },
  timelineDot: {
    position: "absolute",
    left: -15,
    top: 17,
    width: 9,
    height: 9,
    borderRadius: "50%",
    border: "2px solid currentColor"
  },
  revisionMeta: {
    display: "flex",
    alignItems: "baseline",
    justifyContent: "space-between",
    gap: 12,
    flexWrap: "wrap"
  },
  revisionActions: {
    display: "flex",
    gap: 8,
    flexWrap: "wrap",
    marginTop: 8
  }
};

const reasonLabel = (
  reason: PlaymeshHistoryReason,
  translate: PlaymeshTranslate
): string => {
  switch (reason) {
    case "explicit_save":
      return translate(playmeshMessages.historyReasonExplicitSave);
    case "important_change":
      return translate(playmeshMessages.historyReasonImportantChange);
    case "before_restore":
      return translate(playmeshMessages.historyReasonBeforeRestore);
    case "restore":
      return translate(playmeshMessages.historyReasonRestore);
    default:
      return reason || translate(playmeshMessages.historyReasonDefault);
  }
};

const formatTimestamp = (
  timestamp: string,
  localeId: string,
  translate: PlaymeshTranslate
): string => {
  const parsed = Date.parse(timestamp || "");
  return Number.isNaN(parsed)
    ? translate(playmeshMessages.historyUnknownTime)
    : new Date(parsed).toLocaleString(localeId);
};

const usePlaymeshHistory = ({
  fileMetadata,
  project
}: Props): UsePlaymeshHistoryReturn => {
  const { t: playmeshT, localeId } = usePlaymeshLocalization();
  const gdevelopTheme = React.useContext(GDevelopThemeContext);
  const { isMobile } = useResponsiveWindowSize();
  const [panelOpen, setPanelOpen] = React.useState<boolean>(false);
  const [
    versions,
    setVersions
  ] = React.useState<?Array<PlaymeshHistoryVersion>>(null);
  const [error, setError] = React.useState<?string>(null);
  const [busyRevision, setBusyRevision] = React.useState<?number>(null);
  const [diff, setDiff] = React.useState<?PlaymeshHistoryDiff>(null);
  const [diffModel, setDiffModel] = React.useState<?any>(null);
  const [comparisonOpen, setComparisonOpen] = React.useState<boolean>(false);
  const [comparisonError, setComparisonError] = React.useState<?string>(null);
  const [
    selectedVersion,
    setSelectedVersion
  ] = React.useState<?PlaymeshHistoryVersion>(null);
  const gameId = fileMetadata && fileMetadata.gameId;

  React.useEffect(
    () => {
      if (!panelOpen) return;
      const frame = window.requestAnimationFrame(() => {
        const closeButton = document.getElementById(
          "playmesh-version-history-drawer-close"
        );
        if (closeButton) closeButton.focus();
      });
      return () => window.cancelAnimationFrame(frame);
    },
    [panelOpen]
  );

  const loadVersions = React.useCallback(
    async (): Promise<void> => {
      if (!gameId) {
        setVersions([]);
        return;
      }
      setError(null);
      try {
        const response = await listPlaymeshHistory(gameId);
        setVersions(response.versions || []);
      } catch (loadError) {
        console.warn("Unable to load Playmesh GDevelop history", loadError);
        setError(playmeshT(playmeshMessages.historyLoadFailed));
        setVersions(null);
      }
    },
    [gameId, playmeshT]
  );

  React.useEffect(
    () => {
      if (!panelOpen) return;
      loadVersions();
    },
    [panelOpen, loadVersions]
  );

  React.useEffect(
    () => {
      const onHistoryStatus = (event: Event): void => {
        const detail = readHistoryStatusDetail(event);
        if (!detail) return;
        if (!panelOpen || detail.gameId !== gameId) return;
        if (detail.state === "synced") loadVersions();
        if (detail.state === "error") {
          console.warn("Playmesh GDevelop history sync failed", detail.error);
          setError(playmeshT(playmeshMessages.historyUnavailable));
        }
      };
      window.addEventListener(
        "playmesh-gdevelop-history-status",
        onHistoryStatus
      );
      return () =>
        window.removeEventListener(
          "playmesh-gdevelop-history-status",
          onHistoryStatus
        );
    },
    [gameId, loadVersions, panelOpen, playmeshT]
  );

  const compareVersion = React.useCallback(
    async (version: PlaymeshHistoryVersion): Promise<void> => {
      if (!gameId || !versions || !versions.length) return;
      setBusyRevision(version.revision);
      setComparisonOpen(true);
      setComparisonError(null);
      setSelectedVersion(version);
      setDiff(null);
      setDiffModel(null);
      try {
        const newestRevision = versions[0].revision;
        const nextDiff = await getPlaymeshHistoryDiff(
          gameId,
          version.revision,
          newestRevision
        );
        const nextSemanticDiff = buildPlaymeshHistoryDiffSummary({
          before: nextDiff.before,
          after: nextDiff.after,
        });
        setDiff(nextDiff);
        setDiffModel(
          buildPlaymeshHistoryDiffModel(
            nextSemanticDiff,
            nextDiff.resourceEvidence
          )
        );
      } catch (diffError) {
        console.warn("Unable to compare Playmesh GDevelop history", diffError);
        setComparisonError(playmeshT(playmeshMessages.historyCompareFailed));
      } finally {
        setBusyRevision(null);
      }
    },
    [gameId, playmeshT, versions]
  );

  const restoreVersion = React.useCallback(
    async (version: PlaymeshHistoryVersion): Promise<void> => {
      if (!gameId || !fileMetadata || !project) return;
      if (
        !window.confirm(
          playmeshT(playmeshMessages.historyRestoreConfirm, {
            revision: version.revision
          })
        )
      ) {
        return;
      }
      setBusyRevision(version.revision);
      setError(null);
      try {
        await restorePlaymeshHistoryToLocalStore({
          gameId,
          targetRevision: version.revision,
          fileMetadata,
          project
        });
      } catch (restoreError) {
        console.warn(
          "Unable to restore Playmesh GDevelop history",
          restoreError
        );
        setError(playmeshT(playmeshMessages.historyRestoreFailed));
      } finally {
        setBusyRevision(null);
      }
    },
    [fileMetadata, gameId, playmeshT, project]
  );

  const closeHistoryPanel = (): void => {
    setComparisonOpen(false);
    setPanelOpen(false);
  };

  const renderVersionHistoryPanel = (): React.Node => (
    <React.Fragment>
      <Drawer
        open={panelOpen}
        PaperProps={{
          style: {
            ...styles.drawerContent,
            ...(isMobile ? { width: "100vw" } : {}),
            backgroundColor: gdevelopTheme.dialog.backgroundColor
          },
          className: "safe-area-aware-left-container",
          role: "dialog",
          "aria-label": playmeshT(playmeshMessages.historyTitle)
        }}
        ModalProps={{ keepMounted: true }}
        onClose={closeHistoryPanel}
      >
        <DrawerTopBar
          title={
            <span style={styles.drawerTitle}>
              <span aria-hidden="true" style={styles.drawerTitleIcon}>
                <HistoryIcon />
              </span>
              <span>{playmeshT(playmeshMessages.historyTitle)}</span>
            </span>
          }
          onClose={closeHistoryPanel}
          id="playmesh-version-history-drawer"
        />
        <div style={styles.scrollArea}>
          {!gameId ? (
            <Line>
              <Column expand>
                <AlertMessage kind="info">
                  {playmeshT(playmeshMessages.historySaveFirst)}
                </AlertMessage>
              </Column>
            </Line>
          ) : error && !versions ? (
            <PlaceholderError onRetry={loadVersions}>{error}</PlaceholderError>
          ) : !versions ? (
            <PlaceholderLoader />
          ) : (
            <React.Fragment>
              {error && (
                <Line>
                  <Column expand>
                    <AlertMessage kind="warning">
                      {playmeshT(playmeshMessages.historyErrorEditingSafe, {
                        error
                      })}
                    </AlertMessage>
                  </Column>
                </Line>
              )}
              {!versions.length ? (
                <Line>
                  <Column expand>
                    <Text>{playmeshT(playmeshMessages.historyEmpty)}</Text>
                  </Column>
                </Line>
              ) : (
                <div style={styles.timeline}>
                  <span
                    aria-hidden="true"
                    style={{
                      ...styles.timelineRail,
                      backgroundColor: gdevelopTheme.toolbar.separatorColor
                    }}
                  />
                  {versions.map((version, index) => {
                    const selected =
                      !!selectedVersion &&
                      selectedVersion.revision === version.revision;
                    const accentColor = selected
                      ? gdevelopTheme.palette.primary
                      : gdevelopTheme.toolbar.separatorColor;
                    return (
                      <Paper
                        key={version.id}
                        background={selected ? "light" : "dark"}
                        style={{
                          ...styles.revisionCard,
                          borderLeftColor: accentColor
                        }}
                      >
                        <span
                          aria-hidden="true"
                          style={{
                            ...styles.timelineDot,
                            color: accentColor,
                            backgroundColor:
                              gdevelopTheme.dialog.backgroundColor
                          }}
                        />
                        <div style={styles.revisionMeta}>
                          <Text noMargin size="sub-title">
                            {playmeshT(playmeshMessages.historyRevision, {
                              revision: version.revision
                            })}
                            {index === 0
                              ? ` · ${playmeshT(
                                  playmeshMessages.historyCurrent
                                )}`
                              : ""}
                          </Text>
                          <Text
                            noMargin
                            color="secondary"
                            style={{ fontVariantNumeric: "tabular-nums" }}
                          >
                            {formatTimestamp(
                              version.timestamp,
                              localeId,
                              playmeshT
                            )}
                          </Text>
                        </div>
                        <Text noMargin color="secondary">
                          {reasonLabel(version.reason, playmeshT)}
                        </Text>
                        {index !== 0 && (
                          <div style={styles.revisionActions}>
                            <FlatButton
                              label={playmeshT(playmeshMessages.historyCompare)}
                              disabled={busyRevision !== null}
                              onClick={() => compareVersion(version)}
                            />
                            <RaisedButton
                              label={playmeshT(playmeshMessages.historyRestore)}
                              primary
                              disabled={busyRevision !== null}
                              onClick={() => restoreVersion(version)}
                            />
                          </div>
                        )}
                      </Paper>
                    );
                  })}
                </div>
              )}
            </React.Fragment>
          )}
        </div>
      </Drawer>
      <PlaymeshHistoryDiffDialog
        open={comparisonOpen}
        loading={!!selectedVersion && !diff && busyRevision !== null}
        error={comparisonError}
        diff={diff}
        model={diffModel}
        isMobile={isMobile}
        translate={playmeshT}
        theme={gdevelopTheme}
        onClose={() => setComparisonOpen(false)}
      />
    </React.Fragment>
  );

  const onQuitVersionHistory = async (): Promise<void> => {};
  const onCheckoutVersion = async (
    version: ExpandedCloudProjectVersion,
    options?: {| dontSaveCheckedOutVersionStatus?: boolean |}
  ): Promise<boolean> => false;
  const getOrLoadProjectVersion = async (
    versionId: string
  ): Promise<ExpandedCloudProjectVersion> => {
    const versionIndex = versions
      ? versions.findIndex(candidate => candidate.id === versionId)
      : -1;
    const version =
      versions && versionIndex >= 0 ? versions[versionIndex] : null;
    if (!version) {
      throw new Error(playmeshT(playmeshMessages.historyLoadFailed));
    }
    const previousVersion =
      versions && versions[versionIndex + 1]
        ? versions[versionIndex + 1].id
        : null;
    return {
      projectId: version.gameId,
      id: version.id,
      label: version.reason,
      createdAt: version.timestamp,
      previousVersion
    };
  };

  return {
    checkedOutVersionStatus: null,
    openVersionHistoryPanel: () => setPanelOpen(true),
    renderVersionHistoryPanel,
    onQuitVersionHistory,
    onCheckoutVersion,
    getOrLoadProjectVersion
  };
};

export default usePlaymeshHistory;
