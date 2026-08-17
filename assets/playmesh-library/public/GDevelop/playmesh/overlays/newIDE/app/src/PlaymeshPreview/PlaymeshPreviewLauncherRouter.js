// @flow

import * as React from 'react';
import BrowserSWPreviewLauncher from '../ExportAndShare/BrowserExporters/BrowserSWPreviewLauncher';
import {
  type PreparePreviewWindowsOptions,
  type PreviewDebuggerServer,
  type PreviewLauncherProps,
  type PreviewOptions,
} from '../ExportAndShare/PreviewLauncher.flow';
import PlaymeshGatewayPreviewLauncher from './PlaymeshGatewayPreviewLauncher';
import { ensurePlaymeshLocalBrowserSWPreview } from './PlaymeshLocalBrowserSWPreview';
import {
  launchPlaymeshPreview,
  preparePlaymeshPreviewWindows,
} from './PlaymeshPreviewLauncherRouting';
import { playmeshPreviewDebuggerServer } from './PlaymeshPreviewDebuggerServer';

export default class PlaymeshPreviewLauncherRouter extends React.Component<
  PreviewLauncherProps
> {
  // Keep React class instances at the ref boundary. Routing helpers consume
  // their structural launcher methods without coercing an inexact class into
  // GDevelop's exact PreviewLauncherInterface object type.
  _localLauncher /*: ?BrowserSWPreviewLauncher */ = null;
  _gatewayLauncher /*: ?PlaymeshGatewayPreviewLauncher */ = null;
  _usedLocalLauncher = false;
  _usedGatewayLauncher = false;

  canDoNetworkPreview = (): boolean => false;

  getPreviewDebuggerServer = (): ?PreviewDebuggerServer =>
    playmeshPreviewDebuggerServer;

  immediatelyPreparePreviewWindows = (
    options: PreparePreviewWindowsOptions
  ): Array<WindowProxy> | null =>
    preparePlaymeshPreviewWindows({
      options,
      localLauncher: this._localLauncher,
      gatewayLauncher: this._gatewayLauncher,
    });

  launchPreview = async (previewOptions: PreviewOptions): Promise<any> => {
    if (previewOptions.isForInGameEdition) this._usedLocalLauncher = true;
    else this._usedGatewayLauncher = true;
    return launchPlaymeshPreview({
      previewOptions,
      localLauncher: this._localLauncher,
      gatewayLauncher: this._gatewayLauncher,
      ensureLocalPreview: ensurePlaymeshLocalBrowserSWPreview,
    });
  };

  closeAllPreviews = (): void => {
    if (this._usedLocalLauncher) this._localLauncher?.closeAllPreviews?.();
    if (this._usedGatewayLauncher) this._gatewayLauncher?.closeAllPreviews?.();
    this._usedLocalLauncher = false;
    this._usedGatewayLauncher = false;
  };

  render(): React.Node {
    return (
      <React.Fragment>
        <BrowserSWPreviewLauncher
          {...this.props}
          ref={launcher => {
            this._localLauncher = launcher;
          }}
        />
        <PlaymeshGatewayPreviewLauncher
          {...this.props}
          ref={launcher => {
            this._gatewayLauncher = launcher;
          }}
        />
      </React.Fragment>
    );
  }
}
