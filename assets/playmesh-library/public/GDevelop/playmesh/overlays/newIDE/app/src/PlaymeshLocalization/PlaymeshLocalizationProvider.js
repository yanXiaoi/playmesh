// @flow

import * as React from 'react';
import {
  getPlaymeshMessage,
  playmeshLocalizationSession,
} from './PlaymeshLocalizationSession';
import type {
  PlaymeshLocalizationState,
  PlaymeshMessageArguments,
} from './PlaymeshLocalizationSession';
import type { PlaymeshMessageKey } from './PlaymeshMessageKeys';

export type PlaymeshLocalizationContextValue = {|
  ...PlaymeshLocalizationState,
  t: (
    key: PlaymeshMessageKey,
    argumentsMap?: PlaymeshMessageArguments
  ) => string,
|};

type ProviderProps = {|
  children: React.Node,
|};

const PlaymeshLocalizationContext: React.Context<PlaymeshLocalizationContextValue> = React.createContext<PlaymeshLocalizationContextValue>({
  ready: false,
  loading: false,
  stale: false,
  entryAuthoritative: false,
  generation: 0,
  language: 'en',
  targetLanguage: 'en',
  localeId: 'en',
  messages: Object.freeze({}),
  t: getPlaymeshMessage,
});

export const PlaymeshLocalizationSessionProvider = ({
  children,
}: ProviderProps): React.Node => {
  const [state, setState] = React.useState<PlaymeshLocalizationState>(
    playmeshLocalizationSession.getState()
  );

  React.useEffect(() => {
    const unsubscribe = playmeshLocalizationSession.subscribe(setState);
    return unsubscribe;
  }, []);

  return (
    <PlaymeshLocalizationContext.Provider
      value={{ ...state, t: getPlaymeshMessage }}
    >
      {children}
    </PlaymeshLocalizationContext.Provider>
  );
};

export const usePlaymeshLocalization = (): PlaymeshLocalizationContextValue =>
  React.useContext(PlaymeshLocalizationContext);

export default PlaymeshLocalizationContext;
