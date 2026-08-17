// @flow
import * as React from 'react';
import SectionContainer, { SectionRow } from '../HomePage/SectionContainer';
import { Column, Line, Spacer } from '../../../UI/Grid';
import { ColumnStackLayout, LineStackLayout } from '../../../UI/Layout';
import RaisedButton from '../../../UI/RaisedButton';
import FlatButton from '../../../UI/FlatButton';
import Paper from '../../../UI/Paper';
import Text from '../../../UI/Text';
import BackgroundText from '../../../UI/BackgroundText';
import CircularProgress from '../../../UI/CircularProgress';
import Dialog from '../../../UI/Dialog';
import AlertMessage from '../../../UI/AlertMessage';
import {
  type FileMetadataAndStorageProviderName,
  type FileMetadata,
} from '../../../ProjectsStorage';
import PlaymeshPortableProjectImportButton from './PlaymeshPortableProjectImportButton';
import DownloadFileSaveAsDialog from '../../../ProjectsStorage/DownloadFileStorageProvider/DownloadFileSaveAsDialog';
import { usePlaymeshLocalization } from '../../../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../../../PlaymeshLocalization/PlaymeshMessageKeys';
import {
  listAuthoritativeProjects,
  type PlaymeshManagedProjectFile,
} from '../../../ProjectsStorage/PlaymeshLocalStorageProvider';
import {
  createPlaymeshProjectRef,
  deletePlaymeshProject,
} from '../../../PlaymeshProjects/PlaymeshProjectLifecycleClient';

type Props = {|
  project: ?gdProject,
  currentFileMetadata: ?FileMetadata,
  onOpenProject: (
    file: FileMetadataAndStorageProviderName,
    options?: {| ignorePersistedEditorTabs?: boolean |}
  ) => Promise<void>,
  onOpenNewProjectSetupDialog: () => void,
  canOpen: boolean,
  closeProject: () => Promise<void>,
|};

const PlaymeshCreateSection = ({
  project,
  currentFileMetadata,
  onOpenProject,
  onOpenNewProjectSetupDialog,
  canOpen,
  closeProject,
}: Props): React.Node => {
  const [sourceExportDialogOpen, setSourceExportDialogOpen] = React.useState(
    false
  );
  const { t: playmeshT, localeId } = usePlaymeshLocalization();
  const [localProjects, setLocalProjects] = React.useState<
    Array<PlaymeshManagedProjectFile>
  >([]);
  const [projectListError, setProjectListError] = React.useState<?string>(null);
  const [hasSuccessfulProjectList, setHasSuccessfulProjectList] = React.useState(
    false
  );
  const [projectListLoading, setProjectListLoading] = React.useState(true);
  const projectListRequest = React.useRef(0);
  const [projectListUnavailable, setProjectListUnavailable] = React.useState(
    false
  );
  const [projectToDelete, setProjectToDelete] = React.useState<
    ?PlaymeshManagedProjectFile
  >(null);
  const [deletingGameId, setDeletingGameId] = React.useState<?string>(null);

  const reloadProjects = React.useCallback(async () => {
    const requestId = ++projectListRequest.current;
    setProjectListLoading(true);
    try {
      const result = await listAuthoritativeProjects();
      if (requestId !== projectListRequest.current) return;
      setLocalProjects(result.projects);
      setHasSuccessfulProjectList(true);
      setProjectListUnavailable(false);
      setProjectListError(null);
    } catch (error) {
      if (requestId !== projectListRequest.current) return;
      // Keep the last authoritative list. A transport/protocol failure means
      // “temporarily unavailable”, never “there are no projects”.
      setProjectListUnavailable(true);
      setProjectListError(
        error instanceof Error
          ? error.message
          : playmeshT(playmeshMessages.homeProjectListFailed)
      );
    } finally {
      if (requestId === projectListRequest.current) {
        setProjectListLoading(false);
      }
    }
  }, [playmeshT]);

  React.useEffect(
    () => {
      reloadProjects();
      const onStorageStatus = (event: any) => {
        if (event.detail && event.detail.operation !== 'list') reloadProjects();
      };
      window.addEventListener(
        'playmesh-gdevelop-storage-status',
        onStorageStatus
      );
      return () =>
        window.removeEventListener(
          'playmesh-gdevelop-storage-status',
          onStorageStatus
        );
    },
    [reloadProjects]
  );

  const openProject = React.useCallback(
    (projectFile: PlaymeshManagedProjectFile): Promise<void> =>
      onOpenProject(
        {
          storageProviderName: 'PlaymeshLocal',
          fileMetadata: {
            fileIdentifier: projectFile.id,
            name: projectFile.name,
            gameId: projectFile.gameId,
            lastModifiedDate: projectFile.savedAt,
          },
        },
        // A project-manager selection is a deliberate fresh entry. Do not
        // restore browser/Origin-specific editor tabs from a previous exit.
        { ignorePersistedEditorTabs: true }
      ),
    [onOpenProject]
  );

  const deleteProject = React.useCallback(async () => {
    if (!projectToDelete || deletingGameId) return;
    const gameId = projectToDelete.gameId;
    setDeletingGameId(gameId);
    setProjectListError(null);
    try {
      await deletePlaymeshProject({
        projectRef: createPlaymeshProjectRef(gameId),
      });
      const isCurrentProject =
        !!currentFileMetadata && currentFileMetadata.gameId === gameId;
      if (isCurrentProject) await closeProject();
      setProjectToDelete(null);
      await reloadProjects();
    } catch (error) {
      setProjectListError(
        error instanceof Error
          ? error.message
          : playmeshT(playmeshMessages.homeProjectDeleteFailed)
      );
    } finally {
      setDeletingGameId(null);
    }
  }, [
    closeProject,
    currentFileMetadata,
    deletingGameId,
    playmeshT,
    projectToDelete,
    reloadProjects,
  ]);

  return (
    <>
      <SectionContainer flexBody>
        <SectionRow expand>
          <ColumnStackLayout noMargin expand>
            <Line noMargin justifyContent="space-between" alignItems="center">
              <Text size="title">
                {playmeshT(playmeshMessages.homeLocalProjects)}
              </Text>
              <LineStackLayout noMargin>
                <PlaymeshPortableProjectImportButton
                  onOpenProject={onOpenProject}
                  disabled={!canOpen}
                />
                <FlatButton
                  label={playmeshT(playmeshMessages.homeExportSourceZip)}
                  onClick={() => setSourceExportDialogOpen(true)}
                  disabled={!project}
                />
                <RaisedButton
                  primary
                  label={playmeshT(playmeshMessages.homeCreateNewGame)}
                  onClick={onOpenNewProjectSetupDialog}
                />
              </LineStackLayout>
            </Line>
            <Spacer />
            {projectListError && (
              <AlertMessage kind="error">{projectListError}</AlertMessage>
            )}
            {projectListLoading && !localProjects.length ? (
              <Paper variant="outlined" background="dark">
                <div
                  role="status"
                  aria-live="polite"
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    gap: 12,
                    minHeight: 80,
                  }}
                >
                  <CircularProgress size={24} />
                  <Text color="secondary">
                    {playmeshT(playmeshMessages.homeProjectsLoading)}
                  </Text>
                </div>
              </Paper>
            ) : localProjects.length ? (
              localProjects.map(file => {
                const isCurrentProject =
                  !!currentFileMetadata &&
                  currentFileMetadata.gameId === file.gameId;
                return (
                  <Paper
                    key={file.gameId}
                    variant="outlined"
                    background={isCurrentProject ? 'medium' : 'dark'}
                  >
                    <Line justifyContent="space-between" alignItems="center">
                      <Column expand>
                        <Text size="sub-title">
                          {file.name ||
                            playmeshT(playmeshMessages.homeUnnamedProject)}
                        </Text>
                        <Text color="secondary">
                          {isCurrentProject
                            ? playmeshT(playmeshMessages.homeCurrentlyOpen)
                            : file.savedAt
                            ? new Date(file.savedAt).toLocaleString(localeId)
                            : playmeshT(playmeshMessages.homeSavedLocally)}
                        </Text>
                      </Column>
                      <FlatButton
                        label={playmeshT(playmeshMessages.homeOpenLocalProject)}
                        onClick={() => openProject(file)}
                        disabled={!file.hasCurrent || !!deletingGameId}
                      />
                      <FlatButton
                        label={playmeshT(playmeshMessages.homeDeleteProject)}
                        onClick={() => setProjectToDelete(file)}
                        disabled={!!deletingGameId}
                      />
                    </Line>
                  </Paper>
                );
              })
            ) : hasSuccessfulProjectList && !projectListUnavailable ? (
              <Paper variant="outlined" background="dark">
                <Line>
                  <Column expand>
                    <BackgroundText>
                      {playmeshT(playmeshMessages.homeNoLocalProjects)}
                    </BackgroundText>
                    <BackgroundText>
                      {playmeshT(playmeshMessages.homeCreateBlankHint)}
                    </BackgroundText>
                  </Column>
                </Line>
              </Paper>
            ) : null}
          </ColumnStackLayout>
        </SectionRow>
      </SectionContainer>
      {project && sourceExportDialogOpen && (
        <DownloadFileSaveAsDialog
          project={project}
          onDone={() => setSourceExportDialogOpen(false)}
        />
      )}
      {projectToDelete && (
        <Dialog
          open
          title={playmeshT(playmeshMessages.homeDeleteProjectTitle)}
          actions={[
            <FlatButton
              key="cancel"
              label={playmeshT(playmeshMessages.homeDeleteProjectCancel)}
              onClick={() => setProjectToDelete(null)}
              disabled={!!deletingGameId}
            />,
            <RaisedButton
              key="delete"
              primary
              label={playmeshT(playmeshMessages.homeDeleteProjectConfirm)}
              onClick={deleteProject}
              disabled={!!deletingGameId}
            />,
          ]}
          onRequestClose={() => {
            if (!deletingGameId) setProjectToDelete(null);
          }}
          maxWidth="sm"
        >
          <ColumnStackLayout noMargin>
            <Text>
              {playmeshT(playmeshMessages.homeDeleteProjectDescription, {
                name: projectToDelete.name || projectToDelete.gameId,
              })}
            </Text>
            {projectListError && (
              <AlertMessage kind="error">{projectListError}</AlertMessage>
            )}
          </ColumnStackLayout>
        </Dialog>
      )}
    </>
  );
};

export default PlaymeshCreateSection;
