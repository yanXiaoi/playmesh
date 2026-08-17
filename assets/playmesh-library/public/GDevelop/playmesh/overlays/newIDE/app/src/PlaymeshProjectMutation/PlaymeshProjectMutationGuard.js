// @flow

import * as React from 'react';
import { PLAYMESH_PROJECT_MUTATION_EVENT } from './PlaymeshProjectMutationCoordinator';

const blockerStyle = {
  position: 'fixed',
  inset: 0,
  zIndex: 2147483646,
  cursor: 'progress',
  background: 'rgba(0, 0, 0, 0.01)',
};

type Props = {|
  children: React.Node,
|};

type PlaymeshProjectMutationEvent = Event & {
  detail: {|
    locked?: boolean,
    owner?: ?string,
  |},
};

/** AI 写事务期间阻断指针和键盘编辑；autosave/显式保存不显示全局遮罩。 */
export const PlaymeshProjectMutationGuard = ({ children }: Props): React.Node => {
  const [aiWriting, setAiWriting] = React.useState(false);

  React.useEffect(() => {
    const onMutation = (event: PlaymeshProjectMutationEvent): void => {
      const detail = event.detail || {};
      setAiWriting(detail.locked === true && detail.owner === 'gdevelop-ai');
    };
    global.addEventListener(PLAYMESH_PROJECT_MUTATION_EVENT, onMutation);
    return () =>
      global.removeEventListener(PLAYMESH_PROJECT_MUTATION_EVENT, onMutation);
  }, []);

  React.useEffect(
    () => {
      if (!aiWriting) return undefined;
      const stopEditingShortcut = (event: Event): void => {
        event.preventDefault();
        event.stopImmediatePropagation();
      };
      global.addEventListener('keydown', stopEditingShortcut, true);
      global.addEventListener('beforeinput', stopEditingShortcut, true);
      return () => {
        global.removeEventListener('keydown', stopEditingShortcut, true);
        global.removeEventListener('beforeinput', stopEditingShortcut, true);
      };
    },
    [aiWriting]
  );

  return (
    <>
      {children}
      {aiWriting && (
        <div
          style={blockerStyle}
          aria-busy="true"
          data-playmesh-project-mutation="gdevelop-ai"
        />
      )}
    </>
  );
};

export default PlaymeshProjectMutationGuard;
