// @flow

import * as React from 'react';
import AlertMessage from '../UI/AlertMessage';
import FlatButton from '../UI/FlatButton';
import SelectField from '../UI/SelectField';
import SelectOption from '../UI/SelectOption';
import SemiControlledTextField from '../UI/SemiControlledTextField';
import Text from '../UI/Text';
import Toggle from '../UI/Toggle';
import { usePlaymeshLocalization } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { PlaymeshProjectConfigController } from './PlaymeshProjectConfigController';
import {
  playmeshProjectConfigMessages,
  translatePlaymeshProjectConfigMessage,
} from './PlaymeshProjectConfigMessages';

import type {
  PlaymeshProjectConfigControllerState,
  PlaymeshProjectConfigSaveOutcome,
} from './PlaymeshProjectConfigController';
import type { PlaymeshProjectConfigTranslator } from './PlaymeshProjectConfigMessages';
import type { PlaymeshMessageKey } from '../PlaymeshLocalization/PlaymeshMessageKeys';

export type PlaymeshProjectConfigSectionHandle = {|
  saveAfterOfficialApply: (options: {|
    officialApplySucceeded: boolean,
    signal?: ?AbortSignal,
  |}) => Promise<PlaymeshProjectConfigSaveOutcome>,
|};

type Props = {|
  gameId: string,
  controller: PlaymeshProjectConfigController,
  visible?: boolean,
  translate?: ?PlaymeshProjectConfigTranslator,
  onStateChange?: PlaymeshProjectConfigControllerState => void,
|};

const PlaymeshProjectConfigSection: React.ComponentType<{
  ...Props,
  +ref?: React.RefSetter<PlaymeshProjectConfigSectionHandle>,
}> = React.forwardRef<Props, PlaymeshProjectConfigSectionHandle>(
  ({ gameId, controller, visible = true, translate, onStateChange }, ref) => {
    const [
      state,
      setState,
    ] = React.useState<PlaymeshProjectConfigControllerState>(
      controller.getState()
    );
    const { t: sessionTranslate } = usePlaymeshLocalization();
    const activeTranslator = translate || sessionTranslate;
    const t = React.useCallback(
      (key: PlaymeshMessageKey) =>
        translatePlaymeshProjectConfigMessage(key, activeTranslator),
      [activeTranslator]
    );

    React.useEffect(
      () => {
        const unsubscribe = controller.subscribe(nextState => {
          setState(nextState);
          if (onStateChange) onStateChange(nextState);
        });
        return unsubscribe;
      },
      [controller, onStateChange]
    );

    React.useEffect(
      () => {
        // The dialog keeps this component mounted while switching tabs so the
        // App sidecar remains loaded and the imperative Apply handle stays
        // available. A rekey flow may already have moved the same controller
        // to the new gameId; do not supersede that state with a duplicate GET.
        if (controller.getState().gameId !== gameId) {
          void controller.load(gameId);
        }
        return () => controller.cancelActiveOperation(gameId);
      },
      [controller, gameId]
    );

    React.useImperativeHandle(
      ref,
      () => ({
        // 调用方必须先完成官方属性 Apply；sidecar 结果独立返回，不能改写官方结果。
        saveAfterOfficialApply: options =>
          controller.saveAfterOfficialApply(options),
      }),
      [controller]
    );

    const onGameTypeChanged = React.useCallback(
      (
        _event: {| target: {| value: string |} |},
        _index: number,
        value: string
      ) => {
        if (value === 'single' || value === 'online') {
          controller.selectGameType(value);
        }
      },
      [controller]
    );

    // useEffect 执行前不得短暂显示或编辑上一个项目的 sidecar 值。
    const isCurrentGame = state.gameId === gameId;
    const displayedGameType = isCurrentGame ? state.draftGameType : 'single';
    const displayedMinPlayers = isCurrentGame ? state.draftMinPlayers : 1;
    const displayedMaxPlayers = isCurrentGame ? state.draftMaxPlayers : 1;
    const displayedTags = isCurrentGame ? state.draftTags : [];
    const displayedWebRuntimeMultithreading = isCurrentGame
      ? state.draftWebRuntimeMultithreading
      : false;
    const fieldDisabled = !isCurrentGame || state.fieldDisabled;
    const displayedStatus = isCurrentGame ? state.status : 'loading';
    const retryLoad = React.useCallback(
      () => {
        void controller.load(gameId);
      },
      [controller, gameId]
    );
    const errorDiagnostic = [
      state.errorCode ? `code=${state.errorCode}` : null,
      state.errorStatus > 0 ? `status=${state.errorStatus}` : null,
      state.errorRequestId ? `requestId=${state.errorRequestId}` : null,
    ]
      .filter(Boolean)
      .join(' · ');

    if (!visible) return null;

    return (
      <React.Fragment>
        <Text size="block-title">{t(playmeshProjectConfigMessages.title)}</Text>
        <AlertMessage kind="info">
          {t(playmeshProjectConfigMessages.scope)}
        </AlertMessage>
        <SelectField
          id="playmesh-project-game-type"
          fullWidth
          native={false}
          floatingLabelText={t(playmeshProjectConfigMessages.gameType)}
          value={displayedGameType}
          disabled={fieldDisabled}
          onChange={onGameTypeChanged}
        >
          <SelectOption
            value="single"
            label={t(playmeshProjectConfigMessages.single)}
          />
          <SelectOption
            value="online"
            label={t(playmeshProjectConfigMessages.online)}
          />
        </SelectField>
        {displayedGameType === 'online' ? (
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))',
              gap: 12,
            }}
          >
            <SemiControlledTextField
              id="playmesh-project-min-players"
              fullWidth
              type="number"
              step={1}
              min={1}
              max={64}
              value={String(displayedMinPlayers)}
              floatingLabelText={t(playmeshProjectConfigMessages.minPlayers)}
              disabled={fieldDisabled}
              onChange={value => {
                if (/^\d+$/.test(value)) {
                  controller.selectMinPlayers(Number(value));
                }
              }}
            />
            <SemiControlledTextField
              id="playmesh-project-max-players"
              fullWidth
              type="number"
              step={1}
              min={1}
              max={64}
              value={String(displayedMaxPlayers)}
              floatingLabelText={t(playmeshProjectConfigMessages.maxPlayers)}
              disabled={fieldDisabled}
              onChange={value => {
                if (/^\d+$/.test(value)) {
                  controller.selectMaxPlayers(Number(value));
                }
              }}
            />
          </div>
        ) : null}
        <SemiControlledTextField
          id="playmesh-project-tags"
          fullWidth
          value={displayedTags.join(', ')}
          floatingLabelText={t(playmeshProjectConfigMessages.tags)}
          hintText={t(playmeshProjectConfigMessages.tagsHint)}
          disabled={fieldDisabled}
          onChange={value =>
            controller.selectTags(
              value
                .split(/[,，]/)
                .map(tag => tag.trim())
                .filter(Boolean)
            )
          }
        />
        <div style={{ marginTop: 12, marginBottom: 8 }}>
          <Toggle
            labelPosition="right"
            label={t(playmeshProjectConfigMessages.webRuntimeMultithreading)}
            toggled={displayedWebRuntimeMultithreading}
            disabled={fieldDisabled}
            onToggle={(_event, toggled) =>
              controller.selectWebRuntimeMultithreading(toggled)
            }
          />
          <Text size="body-small">
            {t(playmeshProjectConfigMessages.webRuntimeMultithreadingHelp)}
          </Text>
        </div>
        {displayedStatus === 'loading' ? (
          <AlertMessage kind="info">
            {t(playmeshProjectConfigMessages.loading)}
          </AlertMessage>
        ) : null}
        {displayedStatus === 'saving' ? (
          <AlertMessage kind="info">
            {t(playmeshProjectConfigMessages.saving)}
          </AlertMessage>
        ) : null}
        {displayedStatus === 'missing' && state.requiresExplicitSave ? (
          <AlertMessage kind="info">
            {t(playmeshProjectConfigMessages.missingNotSaved)}
          </AlertMessage>
        ) : null}
        {displayedStatus === 'invalid' ? (
          <AlertMessage kind="error">
            {t(playmeshProjectConfigMessages.invalid)}
          </AlertMessage>
        ) : null}
        {displayedStatus === 'unavailable' ? (
          <React.Fragment>
            <AlertMessage kind="warning">
              {t(playmeshProjectConfigMessages.unavailable)}
              {errorDiagnostic ? ` (${errorDiagnostic})` : ''}
            </AlertMessage>
            <FlatButton
              label={t(playmeshProjectConfigMessages.retry)}
              onClick={retryLoad}
            />
          </React.Fragment>
        ) : null}
        {displayedStatus === 'save_failed' ? (
          <AlertMessage kind="warning">
            {t(playmeshProjectConfigMessages.saveFailed)}
            {errorDiagnostic ? ` (${errorDiagnostic})` : ''}
          </AlertMessage>
        ) : null}
        {displayedStatus === 'conflict' ? (
          <AlertMessage kind="warning">
            {t(playmeshProjectConfigMessages.conflict)}
          </AlertMessage>
        ) : null}
      </React.Fragment>
    );
  }
);

export default PlaymeshProjectConfigSection;
