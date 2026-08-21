// @flow

/*::
import type { FileMetadata } from '..';
import type {
  PlaymeshProjectSnapshot,
  PreparedPlaymeshProjectPersistence,
} from './PlaymeshProjectSerializer';
import type { PlaymeshHistoryVersion } from '../../PlaymeshHistory/PlaymeshHistoryClient';
import type { PlaymeshProjectMutationLease } from '../../PlaymeshProjectMutation/PlaymeshProjectMutationCoordinator';
import type { PlaymeshProjectRef } from '../../PlaymeshProjects/PlaymeshProjectLifecycleClient';

type PlaymeshManagedSaveOrigin = 'duplicate' | 'open' | 'create';
type PlaymeshManagedSaveSource = 'user' | 'system';

export type PlaymeshAuthoritativeHistoryResult =
  | {| skipped: 'unsupported' |}
  | {|
      gameId: string,
      current: PlaymeshHistoryVersion,
      historyCreated: false,
      uploadedResources: number,
    |}
  | {|
      gameId: string,
      version: PlaymeshHistoryVersion,
      deduplicated: boolean,
      historyCreated: boolean,
      uploadedResources: number,
    |};

export type PlaymeshManagedSaveInput = {|
  project: gdProject,
  fileMetadata: FileMetadata,
  origin: PlaymeshManagedSaveOrigin,
  source: PlaymeshManagedSaveSource,
  reason: ?string,
  mutationLease: PlaymeshProjectMutationLease,
  shouldBindFileIdentifier: boolean,
|};

type PlaymeshNewProjectAllocationOptions = {|
  project: gdProject,
  origin: 'duplicate' | 'create',
  fileMetadata: FileMetadata,
  snapshot: PlaymeshProjectSnapshot,
|};

type PlaymeshLifecycleAndHistoryOptions = {|
  projectRef: PlaymeshProjectRef,
  origin: 'open',
  fileMetadata: FileMetadata,
  snapshot: PlaymeshProjectSnapshot,
  source: PlaymeshManagedSaveSource,
  reason: ?string,
  mutationLease: PlaymeshProjectMutationLease,
  shouldBindFileIdentifier: boolean,
|};

type PlaymeshAuthoritativeProjectCommitDependencies = {|
  createProjectRef: string => PlaymeshProjectRef,
  ensureGameId: gdProject => string,
  commitNewProjectAllocation: (
    options: PlaymeshNewProjectAllocationOptions
  ) => Promise<void>,
  commitLifecycleAndHistory: (
    options: PlaymeshLifecycleAndHistoryOptions
  ) => Promise<PlaymeshAuthoritativeHistoryResult>,
|};

export type PlaymeshAuthoritativeProjectCommit = (
  prepared: PreparedPlaymeshProjectPersistence,
  input: PlaymeshManagedSaveInput
) => Promise<void | PlaymeshAuthoritativeHistoryResult>;
*/

export const createPlaymeshAuthoritativeProjectCommit = ({
  createProjectRef,
  ensureGameId,
  commitNewProjectAllocation,
  commitLifecycleAndHistory,
} /*: PlaymeshAuthoritativeProjectCommitDependencies */) /*: PlaymeshAuthoritativeProjectCommit */ => async (
  prepared /*: PreparedPlaymeshProjectPersistence */,
  input /*: PlaymeshManagedSaveInput */
) /*: Promise<void | PlaymeshAuthoritativeHistoryResult> */ => {
  const projectRef = createProjectRef(
    prepared.fileMetadata.gameId || ensureGameId(input.project)
  );
  if (input.origin !== 'open') {
    await commitNewProjectAllocation({
      project: input.project,
      origin: input.origin,
      fileMetadata: prepared.fileMetadata,
      snapshot: prepared.snapshot,
    });
    return undefined;
  }
  return commitLifecycleAndHistory({
    projectRef,
    origin: input.origin,
    fileMetadata: prepared.fileMetadata,
    snapshot: prepared.snapshot,
    source: input.source,
    reason: input.reason,
    mutationLease: input.mutationLease,
    shouldBindFileIdentifier: input.shouldBindFileIdentifier,
  });
};
