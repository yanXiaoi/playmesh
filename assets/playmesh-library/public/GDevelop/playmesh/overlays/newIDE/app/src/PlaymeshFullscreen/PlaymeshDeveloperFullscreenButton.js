// @flow

import * as React from 'react';
import TextButton from '../UI/TextButton';
import { usePlaymeshLocalization } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';

type NativeFullscreenBridge = {|
  toggle: () => void,
|};

const getNativeFullscreenBridge = (): ?NativeFullscreenBridge =>
  window.__playmeshDeveloperFullscreen;

const readFullscreenState = (): boolean => {
  if (getNativeFullscreenBridge()) {
    return window.__playmeshDeveloperFullscreenActive === true;
  }
  return !!document.fullscreenElement;
};

export default function PlaymeshDeveloperFullscreenButton(): React.MixedElement {
  const { t: playmeshT } = usePlaymeshLocalization();
  const [active, setActive] = React.useState(readFullscreenState);

  React.useEffect(() => {
    const synchronizeBrowserState = () => setActive(readFullscreenState());
    const synchronizeNativeState = (event: Event) => {
      if (!(event instanceof CustomEvent)) return;
      const detail = event.detail;
      if (detail && typeof detail.active === 'boolean') {
        setActive(detail.active);
      }
    };
    document.addEventListener('fullscreenchange', synchronizeBrowserState);
    window.addEventListener(
      'playmeshdeveloperfullscreenchange',
      synchronizeNativeState
    );
    synchronizeBrowserState();
    return () => {
      document.removeEventListener('fullscreenchange', synchronizeBrowserState);
      window.removeEventListener(
        'playmeshdeveloperfullscreenchange',
        synchronizeNativeState
      );
    };
  }, []);

  const toggleFullscreen = React.useCallback(async () => {
    const nativeBridge = getNativeFullscreenBridge();
    if (nativeBridge) {
      nativeBridge.toggle();
      return;
    }
    try {
      if (document.fullscreenElement) {
        await document.exitFullscreen();
      } else {
        const documentElement = document.documentElement;
        if (!documentElement) return;
        await documentElement.requestFullscreen();
      }
    } catch (error) {
      console.warn('Unable to toggle Playmesh editor fullscreen', error);
    }
  }, []);

  return (
    <TextButton
      id="playmesh-developer-fullscreen-toggle"
      allowBrowserAutoTranslate={false}
      label={playmeshT(
        active ? playmeshMessages.fullscreenExit : playmeshMessages.fullscreenEnter
      )}
      onClick={toggleFullscreen}
    />
  );
}
