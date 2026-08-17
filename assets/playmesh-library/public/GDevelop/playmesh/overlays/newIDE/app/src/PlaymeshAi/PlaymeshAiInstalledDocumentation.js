// @flow

import { mapVector } from '../Utils/MapFor';
import {
  buildExtensionSummary,
  type ExtensionSummary,
} from '../EditorFunctions/SimplifiedProject/ExtensionSummary';

export type PlaymeshAiInstalledDocumentation = {|
  source: 'installed-gdevelop-extension-metadata',
  extensions: Array<ExtensionSummary>,
  missingExtensionNames: Array<string>,
|};

const parseExtensionNames = (value: string): Array<string> => {
  const names = value
    .split(/[,\n]/)
    .map(name => name.trim())
    .filter(Boolean);
  return [...new Set(names)];
};

/**
 * Read only metadata already registered in the pinned GDevelop runtime. This
 * never dereferences help paths and never calls the extension store, so an
 * offline or filtered network cannot turn documentation into a hidden URL
 * fetch path.
 */
export const readPlaymeshInstalledExtensionDocs = ({
  project,
  extensionNames,
}: {|
  project: gdProject,
  extensionNames: string,
|}): PlaymeshAiInstalledDocumentation => {
  const requestedNames = parseExtensionNames(extensionNames);
  const requestedSet = new Set(requestedNames);
  const platformExtensions: Array<gdPlatformExtension> = mapVector(
    project.getCurrentPlatform().getAllPlatformExtensions(),
    extension => extension
  );
  const extensions = platformExtensions
    .filter(extension => requestedSet.has(extension.getName()))
    .map(extension => {
      const extensionName = extension.getName();
      const eventsFunctionsExtension = project.hasEventsFunctionsExtensionNamed(
        extensionName
      )
        ? project.getEventsFunctionsExtension(extensionName)
        : null;
      return buildExtensionSummary({
        gd: global.gd,
        eventsFunctionsExtension,
        extension,
      });
    });
  const found = new Set(extensions.map(extension => extension.extensionName));
  return {
    source: 'installed-gdevelop-extension-metadata',
    extensions,
    missingExtensionNames: requestedNames.filter(name => !found.has(name)),
  };
};

export default readPlaymeshInstalledExtensionDocs;
