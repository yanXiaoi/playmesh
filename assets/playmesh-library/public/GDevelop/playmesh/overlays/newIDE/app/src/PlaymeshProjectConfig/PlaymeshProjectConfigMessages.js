// @flow

import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';

/*::
import type { PlaymeshMessageKey } from '../PlaymeshLocalization/PlaymeshMessageKeys';

type PlaymeshProjectConfigMessageRegistry = $ReadOnly<{|
  title: PlaymeshMessageKey,
  scope: PlaymeshMessageKey,
  gameType: PlaymeshMessageKey,
  single: PlaymeshMessageKey,
  online: PlaymeshMessageKey,
  minPlayers: PlaymeshMessageKey,
  maxPlayers: PlaymeshMessageKey,
  tags: PlaymeshMessageKey,
  tagsHint: PlaymeshMessageKey,
  loading: PlaymeshMessageKey,
  saving: PlaymeshMessageKey,
  missingNotSaved: PlaymeshMessageKey,
  invalid: PlaymeshMessageKey,
  unavailable: PlaymeshMessageKey,
  retry: PlaymeshMessageKey,
  conflict: PlaymeshMessageKey,
  saveFailed: PlaymeshMessageKey,
|}>;
export type PlaymeshProjectConfigTranslator = PlaymeshMessageKey => string;
*/

// Keep the feature-local names for readability, but map every visible string
// to the single App localization registry. The provider then updates this UI
// in the same render as a temporary GDevelop language switch.
export const playmeshProjectConfigMessages /*: PlaymeshProjectConfigMessageRegistry */ = Object.freeze(
  {
    title: playmeshMessages.projectConfigTitle,
    scope: playmeshMessages.projectConfigScope,
    gameType: playmeshMessages.projectConfigGameType,
    single: playmeshMessages.projectConfigSingle,
    online: playmeshMessages.projectConfigOnline,
    minPlayers: playmeshMessages.projectConfigMinPlayers,
    maxPlayers: playmeshMessages.projectConfigMaxPlayers,
    tags: playmeshMessages.projectConfigTags,
    tagsHint: playmeshMessages.projectConfigTagsHint,
    loading: playmeshMessages.projectConfigLoading,
    saving: playmeshMessages.projectConfigSaving,
    missingNotSaved: playmeshMessages.projectConfigMissingNotSaved,
    invalid: playmeshMessages.projectConfigInvalid,
    unavailable: playmeshMessages.projectConfigUnavailable,
    retry: playmeshMessages.projectConfigRetry,
    conflict: playmeshMessages.projectConfigConflict,
    saveFailed: playmeshMessages.projectConfigSaveFailed,
  }
);

export const translatePlaymeshProjectConfigMessage = (
  key /*: PlaymeshMessageKey */,
  translator /*: PlaymeshProjectConfigTranslator */
) /*: string */ => {
  const translated = translator(key);
  return typeof translated === 'string' && translated ? translated : key;
};
