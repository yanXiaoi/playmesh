// @flow

import * as React from 'react';
import FlatButton from '../UI/FlatButton';
import Text from '../UI/Text';
import { LineStackLayout } from '../UI/Layout';
import Window from '../Utils/Window';
import { getSafePlaymeshExtensionSourceUrl } from './PlaymeshExtensionSourceUrl';

type Props = {|
  header: mixed,
|};

const PlaymeshExtensionSourceLink = ({ header }: Props): React.Node => {
  const extensionHeader: any = header;
  const source = getSafePlaymeshExtensionSourceUrl({
    value:
      extensionHeader && typeof extensionHeader === 'object'
        ? extensionHeader.url
        : null,
    baseUrl: document.baseURI,
  });
  if (!source) return null;
  const openSource = (): void => {
    const safeSource = getSafePlaymeshExtensionSourceUrl({
      value: extensionHeader.url,
      baseUrl: document.baseURI,
    });
    if (safeSource && safeSource.kind === 'external') {
      Window.openExternalURL(safeSource.url);
    }
  };
  return (
    <LineStackLayout noMargin alignItems="center">
      <Text noMargin size="body2">
        来源 / Source: {source.provider}
      </Text>
      {source.kind === 'external' ? (
        <FlatButton
          label="查看源提供地址 / View source provider"
          onClick={openSource}
        />
      ) : (
        <Text noMargin size="body2">
          {source.displayUrl}
        </Text>
      )}
    </LineStackLayout>
  );
};

export default PlaymeshExtensionSourceLink;
