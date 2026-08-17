// @flow

import { Trans } from '@lingui/macro';
import * as React from 'react';
import AlertMessage from '../UI/AlertMessage';
import RaisedButton from '../UI/RaisedButton';
import { ColumnStackLayout } from '../UI/Layout';
import Text from '../UI/Text';
import type {
  PlaymeshProjectRekeyControllerState,
  PlaymeshProjectRekeyControllerStatus,
} from './PlaymeshProjectRekeyController';
import { PlaymeshProjectRekeyController } from './PlaymeshProjectRekeyController';

export const usePlaymeshProjectRekeyControllerState = (
  controller /*: PlaymeshProjectRekeyController */
) /*: PlaymeshProjectRekeyControllerState */ => {
  const [state, setState] = React.useState(controller.getState());
  React.useEffect(() => controller.subscribe(setState), [controller]);
  return state;
};

const statusMessage = (
  status /*: PlaymeshProjectRekeyControllerStatus */
) /*: React.Node */ => {
  switch (status) {
    case 'capturing_source':
      return <Trans>Preparing the current local project snapshot...</Trans>;
    case 'applying_properties':
      return <Trans>Applying the new game properties...</Trans>;
    case 'persisting_source':
      return <Trans>Protecting the current local project...</Trans>;
    case 'preparing':
      return (
        <Trans>Preparing the Playmesh project identity migration...</Trans>
      );
    case 'committing':
      return <Trans>Publishing the new local project identity...</Trans>;
    case 'switching_browser':
      return <Trans>Switching the browser project atomically...</Trans>;
    case 'acknowledging':
      return <Trans>Confirming the browser project identity...</Trans>;
    case 'recovering':
      return (
        <Trans>Recovering an interrupted project identity migration...</Trans>
      );
    case 'rolling_back':
      return <Trans>Restoring the previous project identity...</Trans>;
    case 'succeeded':
      return <Trans>The Playmesh project identity was updated.</Trans>;
    case 'rolled_back':
      return (
        <Trans>
          The project identity change was not completed. The previous local
          project was restored.
        </Trans>
      );
    case 'blocked':
      return (
        <Trans>
          The migration state cannot be verified safely. Keep this dialog open
          and retry after the local Playmesh service is available.
        </Trans>
      );
    case 'failed':
      return (
        <Trans>
          The project identity change failed. The previous editor properties
          were restored.
        </Trans>
      );
    default:
      return null;
  }
};

export const PlaymeshProjectRekeyStatus = (
  {
    state,
    onRetry,
  } /*: {|
  state: PlaymeshProjectRekeyControllerState,
  onRetry: () => void,
|} */
) /*: React.Node */ => {
  if (state.status === 'idle') return null;
  const kind =
    state.status === 'failed' || state.status === 'blocked'
      ? 'error'
      : state.status === 'rolled_back'
      ? 'warning'
      : 'info';
  return (
    <ColumnStackLayout noMargin>
      <AlertMessage kind={kind}>
        {statusMessage(state.status)}
        {state.errorMessage ? (
          <Text size="body-small" noMargin>
            {state.errorMessage}
          </Text>
        ) : null}
      </AlertMessage>
      {state.status === 'blocked' ? (
        <RaisedButton
          label={<Trans>Retry recovery</Trans>}
          onClick={onRetry}
          primary
        />
      ) : null}
    </ColumnStackLayout>
  );
};
