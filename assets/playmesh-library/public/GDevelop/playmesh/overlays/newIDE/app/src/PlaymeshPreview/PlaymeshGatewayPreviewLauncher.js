// @flow

import * as React from 'react';
import BrowserPreviewErrorDialog from '../ExportAndShare/BrowserExporters/BrowserPreview/BrowserPreviewErrorDialog';
import {
  type PreparePreviewWindowsOptions,
  type PreviewDebuggerServer,
  type PreviewLauncherProps,
  type PreviewOptions,
} from '../ExportAndShare/PreviewLauncher.flow';
import { createPlaymeshGatewayPreviewPackage } from './PlaymeshGatewayPreviewPackage';
import { uploadPlaymeshGatewayPreview } from './PlaymeshGatewayPreviewClient';
import {
  stopPlaymeshPreview,
  waitForPlaymeshPreviewAppRuntime,
} from './PlaymeshPreviewRunClient';
import { getPlaymeshMessage } from '../PlaymeshLocalization/PlaymeshLocalizationSession';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';
import { playmeshPreviewDebuggerServer } from './PlaymeshPreviewDebuggerServer';

type State = {|
  error: ?Error,
|};

type ActivePreview = {|
  gameId: string,
  previewId: string,
|};

export default class PlaymeshGatewayPreviewLauncher extends React.Component<
  PreviewLauncherProps,
  State
> {
  state: State = { error: null };
  _activePreview: ?ActivePreview = null;
  _abortController: ?AbortController = null;

  componentDidMount(): void {
    global.addEventListener?.('pagehide', this._handlePageHide);
    void this._startDebuggerServer();
  }

  componentWillUnmount(): void {
    global.removeEventListener?.('pagehide', this._handlePageHide);
    this.closeAllPreviews();
  }

  canDoNetworkPreview = (): boolean => false;

  getPreviewDebuggerServer = (): ?PreviewDebuggerServer =>
    playmeshPreviewDebuggerServer;

  _startDebuggerServer = async (): Promise<void> => {
    try {
      await playmeshPreviewDebuggerServer.startServer({
        origin: global.location.origin,
      });
    } catch (error) {
      console.error('Unable to start Playmesh GDevelop debugger', error);
      this.setState({
        error: error instanceof Error ? error : new Error(String(error)),
      });
    }
  };

  // DeveloperPreviewService already launches the staged package through the
  // App's existing DeveloperRun -> GamePage -> GameLauncher runtime chain.
  // Flutter WebView has no browser popup surface, so no window is prepared.
  immediatelyPreparePreviewWindows = (
    _options: PreparePreviewWindowsOptions
  ): Array<WindowProxy> => [];

  _handlePageHide = (): void => {
    this.closeAllPreviews();
  };

  _stopActivePreview = async (): Promise<void> => {
    const active = this._activePreview;
    this._activePreview = null;
    if (!active) return;
    playmeshPreviewDebuggerServer.unbindAppRuntime();
    try {
      await stopPlaymeshPreview({
        gameId: active.gameId,
        previewId: active.previewId,
      });
    } catch (error) {
      // A newer generation may already have replaced this run. Its 409 is an
      // expected no-op and must never stop the newer preview.
      if (!(error && error.code === 'preview_generation_conflict')) {
        console.warn('Unable to stop Playmesh GDevelop preview', error);
      }
    }
  };

  _stopAllActivePreviews = async (): Promise<void> => {
    await this._stopActivePreview();
  };

  closeAllPreviews = (): void => {
    this._abortController?.abort();
    void this._stopAllActivePreviews();
    playmeshPreviewDebuggerServer.closeAllConnections();
  };

  launchPreview = async (previewOptions: PreviewOptions): Promise<void> => {
    if (previewOptions.isForInGameEdition) {
      throw new Error(
        'GDevelop 游戏内编辑器必须使用本地官方预览链，不能进入 Playmesh 包预览。'
      );
    }
    this.setState({ error: null });
    this._abortController?.abort();
    const abortController = new AbortController();
    this._abortController = abortController;
    try {
      const prepared = await createPlaymeshGatewayPreviewPackage({
        previewOptions,
        launcherProps: this.props,
        signal: abortController.signal,
      });
      const response = await uploadPlaymeshGatewayPreview({
        producer: prepared.producer,
        gameId: prepared.gameId,
        signal: abortController.signal,
        confirmBlobFallback: () => {
          console.warn(
            getPlaymeshMessage(playmeshMessages.previewConfirmMemory)
          );
          return true;
        },
      });
      await waitForPlaymeshPreviewAppRuntime({
        initialResponse: response,
        signal: abortController.signal,
      });
      if (abortController.signal.aborted) return;
      playmeshPreviewDebuggerServer.bindAppRuntime({
        gameId: prepared.gameId,
        previewId: response.previewId,
      });
      this._activePreview = {
        gameId: prepared.gameId,
        previewId: response.previewId,
      };
    } catch (error) {
      if (!(abortController.signal.aborted && error?.name === 'AbortError')) {
        console.error('Unable to launch Playmesh GDevelop preview', error);
        this.setState({
          error: error instanceof Error ? error : new Error(String(error)),
        });
      }
      throw error;
    } finally {
      if (this._abortController === abortController) {
        this._abortController = null;
      }
    }
  };

  render(): React.Node {
    const { error } = this.state;
    if (!error) return null;
    return (
      <BrowserPreviewErrorDialog
        error={error}
        onClose={() => this.setState({ error: null })}
      />
    );
  }
}
