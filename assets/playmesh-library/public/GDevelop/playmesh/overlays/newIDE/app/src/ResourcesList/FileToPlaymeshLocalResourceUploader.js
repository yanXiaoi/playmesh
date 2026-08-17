// @flow
import * as React from 'react';
import path from 'path-browserify';
import AlertMessage from '../UI/AlertMessage';
import { Column } from '../UI/Grid';
import GDevelopThemeContext from '../UI/Theme/GDevelopThemeContext';
import {
  allResourceKindsAndMetadata,
  type ChooseResourceOptions,
  type ResourceKind,
} from './ResourceSource';
import { usePlaymeshLocalization } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';

type Props = {|
  options: ChooseResourceOptions,
  onChooseResources: (resources: Array<gdResource>) => void,
  createNewResource: () => gdResource,
  automaticallyOpenInput: boolean,
|};

const getAcceptedExtensions = (resourceKind: ResourceKind): string => {
  const metadata = allResourceKindsAndMetadata.find(({ kind }) => kind === resourceKind);
  return metadata ? metadata.fileExtensions.map(extension => `.${extension}`).join(',') : '';
};

const FileToPlaymeshLocalResourceUploader = ({
  options,
  onChooseResources,
  createNewResource,
  automaticallyOpenInput,
}: Props): React.Node => {
  const { t: playmeshT } = usePlaymeshLocalization();
  const inputRef = React.useRef<?HTMLInputElement>(null);
  const hasOpened = React.useRef(false);
  const gdevelopTheme = React.useContext(GDevelopThemeContext);

  React.useLayoutEffect(
    () => {
      const input = inputRef.current;
      if (automaticallyOpenInput && !hasOpened.current && input) {
        hasOpened.current = true;
        input.click();
      }
    },
    [automaticallyOpenInput]
  );

  return (
    <Column noMargin expand>
      <input
        accept={getAcceptedExtensions(options.resourceKind)}
        style={{ color: gdevelopTheme.text.color.primary }}
        multiple={options.multiSelection}
        type="file"
        ref={inputRef}
        onChange={event => {
          const files = event.currentTarget.files;
          if (!files) return;
          const resources: Array<gdResource> = [];
          for (let index = 0; index < files.length; index++) {
            const file = files[index];
            const newResource = createNewResource();
            const objectUrl = URL.createObjectURL(file);
            newResource.setFile(objectUrl);
            newResource.setName(path.basename(file.name));
            newResource.setOrigin('playmesh-local-resource', file.name);
            resources.push(newResource);
          }
          if (resources.length) onChooseResources(resources);
        }}
      />
      <AlertMessage kind="info">
        {playmeshT(playmeshMessages.resourceLocalStorageInfo)}
      </AlertMessage>
    </Column>
  );
};

export default FileToPlaymeshLocalResourceUploader;
