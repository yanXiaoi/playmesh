// @flow

/*::
export type PlaymeshAutosaveSkipReason =
  | 'autosave_in_progress'
  | 'unchanged'
  | 'revision_conflict'
  | 'project_mutation_locked'
  | 'history_not_created';

export type PlaymeshAutosaveStorageResult =
  | void
  | {| skipped: string |};

export type PlaymeshAutosaveResult =
  | {| saved: true, generation: number |}
  | {| skipped: string |};

export type PlaymeshAutosaveInput = {|
  project: gdProject,
  fileIdentifier: string,
  generation: number,
  trigger?: 'preview' | 'periodic',
  save: () => Promise<PlaymeshAutosaveStorageResult>,
|};

export type PlaymeshAutosaveController = {|
  autosave: (
    input: PlaymeshAutosaveInput
  ) => Promise<PlaymeshAutosaveResult>,
|};
*/

const getAutosaveErrorCode = (error /*: mixed */) /*: ?string */ => {
  if (error === null || typeof error !== 'object') return null;
  const code = Reflect.get(error, 'code');
  return typeof code === 'string' ? code : null;
};

/**
 * Coordinates both preview-triggered and periodic autosaves for the live
 * project. The cursor only moves after the storage provider confirms that the
 * snapshot was persisted. A generation captured while the write is running is
 * intentionally left behind when more edits arrive, so the next tick saves
 * them. Revision conflicts are remembered independently for every project and
 * file identifier, and block both preview and periodic autosaves until a newer
 * local edit generation exists.
 */
export const createPlaymeshAutosaveController = () /*: PlaymeshAutosaveController */ => {
  let activeAttempt /*: ?Object */ = null;
  let lastSuccessfulSnapshot /*: ?{| project: gdProject, fileIdentifier: string, generation: number |} */ = null;
  const conflictGenerationsByProject /*: WeakMap<gdProject, Map<string, number>> */ = new WeakMap();

  const autosave = async (
    input /*: PlaymeshAutosaveInput */
  ) /*: Promise<PlaymeshAutosaveResult> */ => {
    const { project, fileIdentifier, generation, save } = input;
    if (activeAttempt) return { skipped: 'autosave_in_progress' };
    if (
      lastSuccessfulSnapshot &&
      lastSuccessfulSnapshot.project === project &&
      lastSuccessfulSnapshot.fileIdentifier === fileIdentifier &&
      generation <= lastSuccessfulSnapshot.generation
    ) {
      return { skipped: 'unchanged' };
    }
    const projectConflictGenerations = conflictGenerationsByProject.get(
      project
    );
    const conflictGeneration = projectConflictGenerations
      ? projectConflictGenerations.get(fileIdentifier)
      : undefined;
    if (conflictGeneration != null && generation <= conflictGeneration) {
      return { skipped: 'revision_conflict' };
    }

    const attempt = {};
    activeAttempt = attempt;
    try {
      const storageResult = await save();
      if (storageResult && storageResult.skipped) {
        return { skipped: storageResult.skipped };
      }
      lastSuccessfulSnapshot = { project, fileIdentifier, generation };
      if (
        projectConflictGenerations &&
        conflictGeneration != null &&
        generation >= conflictGeneration
      ) {
        projectConflictGenerations.delete(fileIdentifier);
        if (projectConflictGenerations.size === 0) {
          conflictGenerationsByProject.delete(project);
        }
      }
      return { saved: true, generation };
    } catch (error) {
      if (getAutosaveErrorCode(error) === 'gdevelop_revision_conflict') {
        let conflictsForProject = conflictGenerationsByProject.get(project);
        if (!conflictsForProject) {
          conflictsForProject = new Map();
          conflictGenerationsByProject.set(project, conflictsForProject);
        }
        const previousConflictGeneration = conflictsForProject.get(
          fileIdentifier
        );
        if (
          previousConflictGeneration == null ||
          generation > previousConflictGeneration
        ) {
          conflictsForProject.set(fileIdentifier, generation);
        }
      }
      throw error;
    } finally {
      if (activeAttempt === attempt) activeAttempt = null;
    }
  };

  return { autosave };
};
