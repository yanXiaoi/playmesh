// @flow

import * as React from 'react';
import {
  getCurrentTabForPane,
  type EditorTabsState,
} from '../MainFrame/EditorTabs/EditorTabsHandler';

let selectedSceneName /*: ?string */ = null;

const resolveSelectedSceneName = (
  editorTabs /*: EditorTabsState */
) /*: ?string */ => {
  const editorTab = getCurrentTabForPane(editorTabs, 'center');
  if (
    !editorTab ||
    !['layout', 'layout events'].includes(editorTab.kind) ||
    typeof editorTab.projectItemName !== 'string' ||
    !editorTab.projectItemName
  ) {
    return null;
  }
  return editorTab.projectItemName;
};

/**
 * Owns the translation from native editor-tab state to Playmesh AI context.
 * MainFrame only supplies its native state; it does not know what constitutes
 * an AI-selected scene.
 */
export const usePlaymeshAiSelectedScene = (
  editorTabs /*: EditorTabsState */
) /*: void */ => {
  const nextSelectedSceneName = resolveSelectedSceneName(editorTabs);
  selectedSceneName = nextSelectedSceneName;
  React.useEffect(
    () => {
      // Restore the render-time value when React development StrictMode
      // intentionally tears effects down and sets them up again.
      selectedSceneName = nextSelectedSceneName;
      return () => {
        if (selectedSceneName === nextSelectedSceneName) {
          selectedSceneName = null;
        }
      };
    },
    [nextSelectedSceneName]
  );
};

export const getPlaymeshAiSelectedSceneName = () /*: ?string */ =>
  selectedSceneName;
