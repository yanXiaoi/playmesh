// @flow
import { usePlaymeshLocalization } from './PlaymeshLocalizationProvider';
import { playmeshMessages } from './PlaymeshMessageKeys';

export const usePlaymeshAutosavePreferenceLabel = (): string => {
  const { t } = usePlaymeshLocalization();
  return t(playmeshMessages.autosavePreference);
};
