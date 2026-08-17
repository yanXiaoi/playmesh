// @flow

const requiredLauncher = (launcher /*: any */, name /*: string */) /*: any */ => {
  if (!launcher) {
    throw new Error(`GDevelop ${name}预览启动器尚未就绪。`);
  }
  return launcher;
};

export const preparePlaymeshPreviewWindows = ({
  options,
  localLauncher,
  gatewayLauncher,
} /*: {|
  options: any,
  localLauncher: any,
  gatewayLauncher: any,
|} */) /*: any */ => {
  const launcher = options.isForInGameEdition
    ? requiredLauncher(localLauncher, '本地游戏内编辑器')
    : requiredLauncher(gatewayLauncher, 'Playmesh App');
  return launcher.immediatelyPreparePreviewWindows
    ? launcher.immediatelyPreparePreviewWindows(options)
    : null;
};

export const launchPlaymeshPreview = async ({
  previewOptions,
  localLauncher,
  gatewayLauncher,
  ensureLocalPreview,
} /*: {|
  previewOptions: any,
  localLauncher: any,
  gatewayLauncher: any,
  ensureLocalPreview: () => Promise<void>,
|} */) /*: Promise<any> */ => {
  if (previewOptions.isForInGameEdition) {
    await ensureLocalPreview();
    return requiredLauncher(
      localLauncher,
      '本地游戏内编辑器'
    ).launchPreview(previewOptions);
  }
  return requiredLauncher(gatewayLauncher, 'Playmesh App').launchPreview(
    previewOptions
  );
};

