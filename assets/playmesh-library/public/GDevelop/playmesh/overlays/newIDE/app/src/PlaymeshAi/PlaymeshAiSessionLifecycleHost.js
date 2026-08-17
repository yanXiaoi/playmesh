// @flow

import * as React from 'react';
import { type FileMetadata } from '../ProjectsStorage';
import { usePlaymeshLocalization } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { getIsPlaymeshAiEnabled } from './PlaymeshAiFeatureFlags';
import { playmeshAiSessionController } from './PlaymeshAiSessionController';

type Props = {|
  project: ?gdProject,
  fileMetadata: ?FileMetadata,
  getSelectedSceneName: () => ?string,
|};

const FEATURE_POLICY_POLL_INTERVAL_MS = 500;
const VALID_GAME_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

const hasProjectIdentity = (
  project: ?gdProject,
  fileMetadata: ?FileMetadata
): boolean => {
  const gameId = fileMetadata && fileMetadata.gameId;
  return !!(
    project &&
    typeof gameId === 'string' &&
    VALID_GAME_ID.test(gameId) &&
    typeof fileMetadata?.fileIdentifier === 'string' &&
    fileMetadata.fileIdentifier &&
    project.getPackageName() === gameId
  );
};

/**
 * Keeps the authoritative AI session aligned with the WebIDE project even
 * when no AI panel is mounted. The editor-instance lease owns liveness and
 * release; this host only opens/switches/closes project scope.
 */
const PlaymeshAiSessionLifecycleHost = ({
  project,
  fileMetadata,
  getSelectedSceneName,
}: Props): React.Node => {
  const { localeId } = usePlaymeshLocalization();
  const generationRef = React.useRef(0);

  React.useEffect(
    () => {
      let disposed = false;
      const synchronize = async () => {
        const generation = ++generationRef.current;
        try {
          if (!getIsPlaymeshAiEnabled() || !hasProjectIdentity(project, fileMetadata)) {
            if (playmeshAiSessionController.getState().session) {
              playmeshAiSessionController.abandon();
            }
            return;
          }
          await playmeshAiSessionController.open({
            mode: 'agent',
            project: (project: any),
            fileMetadata: (fileMetadata: any),
            locale: localeId,
            selectedSceneName: getSelectedSceneName(),
          });
        } catch (_) {
          // The visible panel owns diagnostics and retry UI. This background
          // host must never turn a transient Gateway failure into an editor
          // crash or duplicate notification channel.
        } finally {
          if (disposed || generation !== generationRef.current) return;
        }
      };
      void synchronize();
      const interval = global.setInterval(
        synchronize,
        FEATURE_POLICY_POLL_INTERVAL_MS
      );
      return () => {
        disposed = true;
        global.clearInterval(interval);
      };
    },
    [fileMetadata, getSelectedSceneName, localeId, project]
  );

  return null;
};

export default PlaymeshAiSessionLifecycleHost;
