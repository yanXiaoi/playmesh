// @flow
import * as React from 'react';
import { t } from '@lingui/macro';
import {
  type StorageProvider,
  type SaveAsLocation,
  type SaveAsOptions,
  type FileMetadata,
} from '..';
import Computer from '../../UI/CustomSvgIcons/Computer';
import { type MessageDescriptor } from '../../Utils/i18n/MessageDescriptor.flow';
import SaveAsOptionsDialog from '../SaveAsOptionsDialog';
import PlaymeshLocalProjectPicker from './PlaymeshLocalProjectPicker';
import {
  createRestoredStoredProject,
  prepareProjectPersistence,
  restoreStoredResources,
  type PlaymeshProjectSnapshot,
} from './PlaymeshProjectSerializer';
import { unsplitPlaymeshProject } from './PlaymeshProjectFiles';
import {
  createPlaymeshManagedProjectStorageController,
  openPlaymeshProjectWithPreparedRestoreRecovery,
} from './PlaymeshManagedProjectStorageController';
import {
  createPlaymeshAuthoritativeProjectCommit,
  type PlaymeshAuthoritativeHistoryResult,
  type PlaymeshManagedSaveInput,
} from './PlaymeshAuthoritativeProjectCommit';
import {
  ensureGDevelopGameId,
  generateCopiedGDevelopGameId,
} from '../../PlaymeshManifest/PlaymeshGDevelopManifestController';
import {
  PlaymeshProjectAllocationError,
  allocatePlaymeshProjectSnapshot,
} from '../../PlaymeshProjects/PlaymeshProjectAllocationCoordinator';
import {
  createPlaymeshProject,
  createPlaymeshProjectRef,
  listPlaymeshProjects,
  openPlaymeshProject,
  runPlaymeshProjectLifecycleSoft,
  updatePlaymeshProject,
  type PlaymeshManagedProjectListResponse,
  type PlaymeshProjectRef,
} from '../../PlaymeshProjects/PlaymeshProjectLifecycleClient';
import {
  loadPlaymeshHistoryCurrentProject,
  PlaymeshHistoryError,
  syncPlaymeshHistory,
} from '../../PlaymeshHistory/PlaymeshHistoryClient';
import { abortPreparedPlaymeshHistoryRestore } from '../../PlaymeshHistory/PlaymeshHistoryRestoreClient';
import {
  runPlaymeshProjectMutation,
  tryRunPlaymeshProjectAutosave,
  type PlaymeshProjectMutationLease,
} from '../../PlaymeshProjectMutation/PlaymeshProjectMutationCoordinator';
import { getPlaymeshMessage } from '../../PlaymeshLocalization/PlaymeshLocalizationSession';
import {
  playmeshMessages,
  type PlaymeshMessageKey,
} from '../../PlaymeshLocalization/PlaymeshMessageKeys';

type LifecycleAndHistoryCommitOptions = {|
  projectRef: PlaymeshProjectRef,
  origin: 'open',
  fileMetadata: FileMetadata,
  snapshot: PlaymeshProjectSnapshot,
  source: 'user' | 'system',
  reason: ?string,
  mutationLease: PlaymeshProjectMutationLease,
  shouldBindFileIdentifier: boolean,
|};

type SaveAsSelection = {|
  saveAsLocation: ?SaveAsLocation,
  saveAsOptions: ?SaveAsOptions,
|};

export type PlaymeshManagedProjectFile = {|
  id: string,
  name: string,
  gameId: string,
  projectFiles: Array<mixed>,
  resources: Array<mixed>,
  savedAt: number,
  hasCurrent: boolean,
|};

const createId = (): string => {
  if (window.crypto && typeof window.crypto.randomUUID === 'function') {
    return window.crypto.randomUUID();
  }
  return `${Date.now().toString(36)}-${Math.random()
    .toString(36)
    .slice(2)}`;
};

const pendingSaveAsOrigins = new Map<string, 'duplicate' | 'open'>();

const boundedDiagnosticField = (value: mixed, fallback: string): string => {
  const normalized = typeof value === 'string' ? value.trim() : '';
  return (normalized || fallback).replace(/[\r\n\t]/g, ' ').slice(0, 240);
};

const sanitizeOperation = (value: mixed): string => {
  const operation = boundedDiagnosticField(value, 'gdevelop.project.open');
  // Never surface a developer bootstrap token if a future caller passes an
  // absolute or query-bearing URL instead of the current relative endpoint.
  return operation.replace(/\?[^\s]*/g, '');
};

export const getPlaymeshProjectOpenDiagnostic = (error: mixed): string => {
  const candidate: any = error;
  const details =
    candidate && candidate.details && typeof candidate.details === 'object'
      ? candidate.details
      : null;
  const requestId =
    candidate?.requestId || (details && details.requestId) || '-';
  const status = Number.isSafeInteger(candidate?.status)
    ? String(candidate.status)
    : '0';
  return [
    `operation=${sanitizeOperation(candidate?.operation)}`,
    `status=${status}`,
    `code=${boundedDiagnosticField(candidate?.code, 'unknown_error')}`,
    `requestId=${boundedDiagnosticField(requestId, '-')}`,
  ].join(' ');
};

const getProjectAllocationMessageKey = (
  error: any
): PlaymeshMessageKey => {
  const status = Number.isSafeInteger(error?.status) ? error.status : 0;
  const code = typeof error?.code === 'string' ? error.code : '';
  if (code === 'gdevelop_project_allocation_locked') {
    return playmeshMessages.storageAllocationLocked;
  }
  if (status === 401 || status === 403) {
    return playmeshMessages.storageAllocationUnauthorized;
  }
  if (status === 404) return playmeshMessages.storageAllocationNotFound;
  if (status === 409) return playmeshMessages.storageAllocationConflict;
  if (code === 'allocation_network_error' || code === 'fetch_unavailable') {
    return playmeshMessages.storageAllocationNetwork;
  }
  if (code === 'allocation_request_timeout') {
    return playmeshMessages.storageAllocationTimeout;
  }
  if (
    code === 'invalid_response' ||
    code === 'invalid_allocation_snapshot' ||
    code === 'allocation_resource_hash_mismatch'
  ) {
    return playmeshMessages.storageAllocationProtocol;
  }
  return playmeshMessages.storageAllocationGeneric;
};

const getProjectLocation = ({
  projectName,
  saveAsLocation,
}: {|
  projectName: string,
  saveAsLocation: ?SaveAsLocation,
  newProjectsDefaultFolder?: string,
|}): SaveAsLocation => ({
  fileIdentifier:
    (saveAsLocation && saveAsLocation.fileIdentifier) || createId(),
  name: projectName,
  gameId:
    (saveAsLocation && saveAsLocation.gameId) || generateCopiedGDevelopGameId(),
});

const renderNewProjectSaveAsLocationChooser = (): React.Node => null;

const findManagedProject = (
  response: PlaymeshManagedProjectListResponse,
  projectRef: PlaymeshProjectRef
) =>
  response.projects.find(
    project => project.identity.gameId === projectRef.gameId
  );

const createOrResumePlaymeshProject = async ({
  projectRef,
  origin,
  fileMetadata,
}: {|
  projectRef: PlaymeshProjectRef,
  origin: 'duplicate' | 'create',
  fileMetadata: FileMetadata,
|}): Promise<void> => {
  try {
    await createPlaymeshProject({
      projectRef,
      origin,
      fileIdentifier: fileMetadata.fileIdentifier,
      name: fileMetadata.name,
    });
  } catch (error) {
    if (!error || error.code !== 'project_id_conflict') throw error;
    // 创建根成功而 current 尚未提交时，重试必须识别自己的 fileIdentifier；
    // 不能因为 gameId 相同就接管另一个工程。
    const response = await listPlaymeshProjects();
    const existing = findManagedProject(response, projectRef);
    if (
      !existing ||
      !existing.identity.fileIdentifiers.includes(fileMetadata.fileIdentifier)
    ) {
      throw error;
    }
    await openPlaymeshProject({
      projectRef,
      fileIdentifier: fileMetadata.fileIdentifier,
      name: fileMetadata.name,
    });
  }
};

const commitLifecycleAndHistory = async ({
  projectRef,
  origin,
  fileMetadata,
  snapshot,
  source,
  reason,
  mutationLease,
  shouldBindFileIdentifier,
}: LifecycleAndHistoryCommitOptions): Promise<PlaymeshAuthoritativeHistoryResult> => {
  // Opening a project already binds its existing fileIdentifier. Only an
  // explicit Save As that keeps the same gameId introduces a new identifier
  // and needs the lifecycle endpoint before committing current/history.
  if (origin === 'open') {
    if (shouldBindFileIdentifier) {
      await openPlaymeshProject({
        projectRef,
        fileIdentifier: fileMetadata.fileIdentifier,
        name: fileMetadata.name,
      });
    }
  } else {
    await createOrResumePlaymeshProject({
      projectRef,
      origin,
      fileMetadata,
    });
  }
  const historyResult = await syncPlaymeshHistory({
    gameId: projectRef.gameId,
    snapshot,
    source,
    reason,
    mutationLease,
  });
  if (historyResult.skipped === 'unsupported') {
    throw new PlaymeshHistoryError(
      'history_unsupported',
      '当前 Playmesh 无法提交 GDevelop 工程。'
    );
  }
  return historyResult;
};

const commitNewProjectAllocation = async ({
  project,
  origin,
  fileMetadata,
  snapshot,
}: {|
  project: gdProject,
  origin: 'duplicate' | 'create',
  fileMetadata: FileMetadata,
  snapshot: PlaymeshProjectSnapshot,
|}): Promise<void> => {
  const gameId = fileMetadata.gameId;
  const projectUuid = String(project.getProjectUuid() || '').trim();
  if (!gameId || !projectUuid) {
    throw new PlaymeshProjectAllocationError(
      'invalid_project_identity',
      'GDevelop 工程缺少 gameId 或 projectUuid，无法创建 Playmesh 本地工程。'
    );
  }
  await allocatePlaymeshProjectSnapshot({
    fileIdentifier: fileMetadata.fileIdentifier,
    gameId,
    name: fileMetadata.name || project.getName(),
    origin,
    projectUuid,
    snapshot,
  });
};

const dispatchProjectListDiagnostics = (
  response: PlaymeshManagedProjectListResponse
): void => {
  if (!response.diagnostics.length) return;
  window.dispatchEvent(
    new CustomEvent('playmesh-gdevelop-project-list-diagnostics', {
      detail: {
        requestId: response.requestId,
        diagnostics: response.diagnostics,
        timestamp: Date.now(),
      },
    })
  );
};

export const listAuthoritativeProjects = async (): Promise<{|
  activeGameId: ?string,
  projects: Array<PlaymeshManagedProjectFile>,
  diagnostics: Array<Object>,
|}> => {
  const response = await listPlaymeshProjects();
  dispatchProjectListDiagnostics(response);
  const projects = response.projects.map(project => {
    const identity = project.identity;
    const updatedAt = Date.parse(identity.updatedAt);
    return {
      id: identity.fileIdentifiers[0] || identity.gameId,
      name: identity.name || identity.gameId,
      gameId: identity.gameId,
      projectFiles: ([]: Array<mixed>),
      resources: ([]: Array<mixed>),
      savedAt: updatedAt,
      hasCurrent: project.hasCurrent,
    };
  });
  projects.sort((left, right) => {
    const updated = right.savedAt - left.savedAt;
    return updated !== 0 ? updated : left.gameId.localeCompare(right.gameId);
  });
  return {
    activeGameId: response.activeGameId,
    projects,
    diagnostics: response.diagnostics,
  };
};

const openAuthoritativeProjectUnderLease = async (
  fileMetadata: FileMetadata
): Promise<Object> => {
  if (!fileMetadata.gameId) {
    throw new PlaymeshHistoryError(
      'invalid_project_id',
      'GDevelop 工程缺少 Playmesh gameId。'
    );
  }
  const projectRef = createPlaymeshProjectRef(fileMetadata.gameId);
  const openProject = () =>
    openPlaymeshProject({
      projectRef,
      fileIdentifier: fileMetadata.fileIdentifier,
      name: fileMetadata.name,
    });
  await openPlaymeshProjectWithPreparedRestoreRecovery({
    openProject,
    recoverPreparedRestore: () =>
      abortPreparedPlaymeshHistoryRestore({ gameId: projectRef.gameId }),
  });
  const current = await loadPlaymeshHistoryCurrentProject(projectRef.gameId);
  if (!current) {
    throw new PlaymeshHistoryError(
      'current_not_found',
      'Playmesh 中尚无可打开的 GDevelop current。'
    );
  }
  const versionTime = Date.parse(current.version.timestamp);
  const restored = createRestoredStoredProject({
    fileMetadata,
    projectFiles: current.projectFiles,
    resources: current.resources,
    savedAt: Number.isFinite(versionTime) ? versionTime : Date.now(),
  });
  return {
    content: restoreStoredResources(
      await unsplitPlaymeshProject(current.projectFiles),
      current.resources
    ),
    fileMetadata: restored.fileMetadata,
    storedProject: restored.storedProject,
  };
};

const openAuthoritativeProject = async (
  fileMetadata: FileMetadata
): Promise<Object> => {
  const gameId = fileMetadata.gameId;
  if (!gameId) {
    return openAuthoritativeProjectUnderLease(fileMetadata);
  }
  return runPlaymeshProjectMutation({
    gameId,
    owner: 'project-open',
    operation: () => openAuthoritativeProjectUnderLease(fileMetadata),
  });
};

const commitAuthoritativeProject = createPlaymeshAuthoritativeProjectCommit({
  createProjectRef: createPlaymeshProjectRef,
  ensureGameId: ensureGDevelopGameId,
  commitNewProjectAllocation,
  commitLifecycleAndHistory,
});

const managedStorage = createPlaymeshManagedProjectStorageController({
  listAuthoritativeProjects,
  openAuthoritativeProject,
  prepareProject: (input: PlaymeshManagedSaveInput) =>
    prepareProjectPersistence(input.project, input.fileMetadata),
  commitAuthoritativeProject,
});

export default ({
  internalName: 'PlaymeshLocal',
  name: t`Playmesh local projects`,
  renderIcon: props => <Computer fontSize={props.size} />,
  getProjectLocation,
  renderNewProjectSaveAsLocationChooser,
  createOperations: ({ setDialog, closeDialog }) => ({
    onOpenWithPicker: async (): Promise<?FileMetadata> => {
      const projectList = await managedStorage.listProjects();
      return new Promise<?FileMetadata>(resolve => {
        const finish = (result: ?FileMetadata): void => {
          closeDialog();
          resolve(result);
        };
        setDialog(() => (
          <PlaymeshLocalProjectPicker
            projects={projectList.projects}
            diagnostics={projectList.diagnostics}
            onChoose={project =>
              finish({
                fileIdentifier: project.id,
                name: project.name,
                gameId: project.gameId,
                lastModifiedDate: project.savedAt,
              })
            }
            onClose={() => finish(null)}
          />
        ));
      });
    },
    onOpen: async (fileMetadata: FileMetadata) => {
      const opened = await managedStorage.openProject(fileMetadata);
      return { content: opened.content };
    },
    onSaveProject: async (project: gdProject, fileMetadata: FileMetadata) => {
      const gameId = fileMetadata.gameId || ensureGDevelopGameId(project);
      return runPlaymeshProjectMutation({
        gameId,
        owner: 'explicit-save',
        operation: async mutationLease => {
          const saved = await managedStorage.saveProject({
            project,
            fileMetadata,
            origin: fileMetadata.lastModifiedDate ? 'open' : 'create',
            source: 'user',
            reason: 'explicit_save',
            mutationLease,
            shouldBindFileIdentifier: false,
          });
          return {
            wasSaved: true,
            fileMetadata: saved.prepared.fileMetadata,
          };
        },
      });
    },
    onChooseSaveProjectAsLocation: async ({
      project,
      displayOptionToGenerateNewProjectUuid,
    }): Promise<SaveAsSelection> =>
      new Promise<SaveAsSelection>(resolve => {
        const finish = (result: SaveAsSelection): void => {
          closeDialog();
          resolve(result);
        };
        setDialog(() => (
          <SaveAsOptionsDialog
            nameSuggestion={`${project.getName()} - Copy`}
            displayOptionToGenerateNewProjectUuid={
              displayOptionToGenerateNewProjectUuid
            }
            onCancel={() =>
              finish({ saveAsLocation: null, saveAsOptions: null })
            }
            onSave={({ name, generateNewProjectUuid }) => {
              const fileIdentifier = createId();
              const gameId = generateNewProjectUuid
                ? generateCopiedGDevelopGameId()
                : ensureGDevelopGameId(project);
              pendingSaveAsOrigins.set(
                fileIdentifier,
                generateNewProjectUuid ? 'duplicate' : 'open'
              );
              finish({
                saveAsLocation: { fileIdentifier, name, gameId },
                saveAsOptions: {
                  generateNewProjectUuid,
                  setProjectNameFromLocation: true,
                },
              });
            }}
          />
        ));
      }),
    onSaveProjectAs: async (project, saveAsLocation, options) => {
      const fileIdentifier = saveAsLocation && saveAsLocation.fileIdentifier;
      if (!saveAsLocation || !fileIdentifier) {
        throw new Error('A Playmesh local project location was not chosen.');
      }
      options.onStartSaving();
      // 新建工程由 GDevelop 直接使用 getProjectLocation 的结果，不会先经过
      // onChooseSaveProjectAsLocation，因此 pendingSaveAsOrigins 中没有记录。
      // 这种首次保存必须进入 allocation/create；只有显式“另存为”才会提前
      // 写入 duplicate/open 来源。
      const origin = pendingSaveAsOrigins.get(fileIdentifier) || 'create';
      pendingSaveAsOrigins.delete(fileIdentifier);
      const gameId = saveAsLocation.gameId || ensureGDevelopGameId(project);
      const fileMetadata: FileMetadata = {
        fileIdentifier,
        name: saveAsLocation.name || project.getName(),
        gameId,
      };
      return runPlaymeshProjectMutation({
        gameId,
        owner: 'explicit-save-as',
        operation: async mutationLease => {
          if (saveAsLocation.gameId) {
            project.setPackageName(saveAsLocation.gameId);
          }
          await options.onMoveResources({ newFileMetadata: fileMetadata });
          const saved = await managedStorage.saveProject({
            project,
            fileMetadata,
            origin,
            source: 'user',
            reason: 'explicit_save',
            mutationLease,
            shouldBindFileIdentifier: origin === 'open',
          });
          return {
            wasSaved: true,
            fileMetadata: saved.prepared.fileMetadata,
          };
        },
      });
    },
    onChangeProjectProperty: async (project, fileMetadata, properties) => {
      const gameId = fileMetadata.gameId || ensureGDevelopGameId(project);
      const projectRef = createPlaymeshProjectRef(gameId);
      // 属性通知不是保存确认；失败由状态事件展示，下一次正式保存仍会提交完整 current。
      runPlaymeshProjectLifecycleSoft({
        projectRef,
        action: () =>
          updatePlaymeshProject({
            projectRef,
            fileIdentifier: fileMetadata.fileIdentifier,
            name: properties.name,
          }),
      });
      return null;
    },
    onAutoSaveProject: async (
      project: gdProject,
      fileMetadata: FileMetadata
    ): Promise<void | {| skipped: string |}> => {
      const gameId = fileMetadata.gameId || ensureGDevelopGameId(project);
      const autosaveResult = await tryRunPlaymeshProjectAutosave({
        gameId,
        operation: mutationLease =>
          managedStorage.saveProject({
            project,
            fileMetadata,
            origin: 'open',
            source: 'system',
            reason: 'autosave',
            mutationLease,
            shouldBindFileIdentifier: false,
          }),
      });
      if ('skipped' in autosaveResult) {
        const skippedResult: {| skipped: string |} = {
          skipped: autosaveResult.skipped,
        };
        return skippedResult;
      }
      const historyResult = autosaveResult.value.authoritativeResult;
      if (
        historyResult &&
        'historyCreated' in historyResult &&
        historyResult.historyCreated === false &&
        (!('deduplicated' in historyResult) ||
          historyResult.deduplicated !== true)
      ) {
        // current 已落盘但可见 revision 未创建。不要前移自动保存游标，
        // 下一次周期继续通过新的 CAS baseRevision 重试历史提交。
        const skippedResult: {| skipped: string |} = {
          skipped: 'history_not_created',
        };
        return skippedResult;
      }
      return undefined;
    },
    getOpenErrorMessage: (error: Error): MessageDescriptor => {
      const diagnostic = getPlaymeshProjectOpenDiagnostic(error);
      return t`Unable to open the Playmesh local project. ${diagnostic}`;
    },
    getWriteErrorMessage: (error: Error): MessageDescriptor => {
      const allocationError: any = error;
      const key = getProjectAllocationMessageKey(allocationError);
      const requestId =
        typeof allocationError?.requestId === 'string' &&
        allocationError.requestId
          ? allocationError.requestId
          : '-';
      // 返回 Playmesh 会话已经本地化并完成占位符插值的字符串。
      // GDevelop 5.6.276 使用 Lingui v2；手写 { id, message } 描述符时
      // message 会被忽略，未知的 id 会作为原始键名显示在创建项目弹窗中。
      return getPlaymeshMessage(key, { requestId });
    },
  }),
}: StorageProvider);
