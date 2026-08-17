// @flow

import * as React from 'react';
import RobotIcon from '../ProjectCreation/RobotIcon';
import TextButton from '../UI/TextButton';
import { useInterval } from '../Utils/UseInterval';
import { useIsMounted } from '../Utils/UseIsMounted';
import { AiRequestContext } from '../AiGeneration/AiRequestContext';
import integrationClasses from './PlaymeshAiIntegration.module.css';
import { type EditorTabsState } from '../MainFrame/EditorTabs/EditorTabsHandler';
import PlaymeshDeveloperFullscreenButton from '../PlaymeshFullscreen/PlaymeshDeveloperFullscreenButton';
import {
  renderPlaymeshAiEditorContainer,
  type PlaymeshAiEditorInterface,
} from './PlaymeshAiEditorContainer';
import PlaymeshAiSessionLifecycleHost from './PlaymeshAiSessionLifecycleHost';
import { getIsPlaymeshAiEnabled } from './PlaymeshAiFeatureFlags';
import {
  getPlaymeshAiSelectedSceneName,
  usePlaymeshAiSelectedScene,
} from './PlaymeshAiSelectedScene';

export { renderPlaymeshAiEditorContainer };
export type { PlaymeshAiEditorInterface };

export const PLAYMESH_AI_EDITOR_LABEL = 'PlayMesh AI';

export const usePlaymeshAiIntegration = (
  editorTabs /*: EditorTabsState */
) /*: void */ => {
  usePlaymeshAiSelectedScene(editorTabs);
};

export const canOpenPlaymeshAi = () /*: boolean */ =>
  getIsPlaymeshAiEnabled();

export const getPlaymeshAiEditorExtraProps = ({
  continueProcessingFunctionCallsOnMount,
} /*: {|
  continueProcessingFunctionCallsOnMount?: boolean,
|} */) /*: {| continueProcessingFunctionCallsOnMount?: boolean |} */ => ({
  continueProcessingFunctionCallsOnMount,
});

export const PlaymeshAiIntegrationHost = ({
  project,
  fileMetadata,
} /*: {|
  project: ?gdProject,
  fileMetadata: any,
|} */) /*: React.Node */ => (
  <PlaymeshAiSessionLifecycleHost
    project={project}
    fileMetadata={fileMetadata}
    getSelectedSceneName={getPlaymeshAiSelectedSceneName}
  />
);

const WINDOW_NON_DRAGGABLE_PART_CLASS_NAME =
  'title-bar-non-draggable-part';

const titlebarStyles = {
  askAiContainer: {
    zIndex: 0,
    marginBottom: 4,
    marginRight: 1,
    marginLeft: 2,
  },
  fullscreenContainer: {
    zIndex: 0,
    marginBottom: 4,
    marginRight: 1,
    marginLeft: 1,
  },
};

const useIsAskAiIconAnimated = (shouldDisplayAskAi /*: boolean */) => {
  const isMounted = useIsMounted();
  const [isAnimated, setIsAnimated] = React.useState(true);
  const animate = React.useCallback(
    (animationDuration /*: number */) => {
      if (!isMounted.current) return;
      setIsAnimated(true);
      setTimeout(() => {
        if (isMounted.current) setIsAnimated(false);
      }, animationDuration);
    },
    [isMounted]
  );
  React.useEffect(() => {
    animate(9000);
  }, [animate]);
  useInterval(() => animate(8000), shouldDisplayAskAi ? 20 * 60 * 1000 : null);
  return isAnimated;
};

/** Owns all Playmesh-specific titlebar visibility, branding and fullscreen UI. */
export const PlaymeshAiTitlebarActions = ({
  displayAskAi,
  onAskAiClicked,
  isRightMostPane,
} /*: {|
  displayAskAi: boolean,
  onAskAiClicked: () => void,
  isRightMostPane: boolean,
|} */) /*: React.Node */ => {
  const shouldDisplayAskAi = getIsPlaymeshAiEnabled() && displayAskAi;
  const { getWorkingAiRequest } = React.useContext(AiRequestContext);
  const isAiWorking = !!getWorkingAiRequest();
  const isAnimated = useIsAskAiIconAnimated(shouldDisplayAskAi);
  const [isGlowing, setIsGlowing] = React.useState(false);
  const glowTimeoutRef = React.useRef<?TimeoutID>(null);
  const triggerGlow = React.useCallback(() => {
    if (glowTimeoutRef.current) clearTimeout(glowTimeoutRef.current);
    setIsGlowing(true);
    glowTimeoutRef.current = setTimeout(() => {
      setIsGlowing(false);
      glowTimeoutRef.current = null;
    }, 1000);
  }, []);
  React.useEffect(
    () => () => {
      if (glowTimeoutRef.current) clearTimeout(glowTimeoutRef.current);
    },
    []
  );
  const previousDisplayRef = React.useRef(shouldDisplayAskAi);
  React.useEffect(
    () => {
      if (shouldDisplayAskAi && !previousDisplayRef.current) triggerGlow();
      previousDisplayRef.current = shouldDisplayAskAi;
    },
    [shouldDisplayAskAi, triggerGlow]
  );
  useInterval(triggerGlow, shouldDisplayAskAi && isAiWorking ? 5000 : null);

  return (
    <React.Fragment>
      {shouldDisplayAskAi ? (
        <div
          style={titlebarStyles.askAiContainer}
          className={WINDOW_NON_DRAGGABLE_PART_CLASS_NAME}
        >
          <div
            className={
              isGlowing ? integrationClasses.askAiGlow : undefined
            }
          >
            <TextButton
              icon={
                <RobotIcon
                  size={16}
                  rotating={isAnimated || isAiWorking}
                />
              }
              label={PLAYMESH_AI_EDITOR_LABEL}
              onClick={onAskAiClicked}
            />
          </div>
        </div>
      ) : null}
      {isRightMostPane ? (
        <div
          style={titlebarStyles.fullscreenContainer}
          className={WINDOW_NON_DRAGGABLE_PART_CLASS_NAME}
        >
          <PlaymeshDeveloperFullscreenButton />
        </div>
      ) : null}
    </React.Fragment>
  );
};
