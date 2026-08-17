// @flow

/*::
export type PlaymeshRuntimeConfigStatus =
  | 'online'
  | 'single'
  | 'missing'
  | 'invalid'
  | 'unavailable';
export type PlaymeshRuntimeScanActivation = 'enabled' | 'disabled' | 'unknown';
export type PlaymeshRuntimeTarget = 'preview' | 'publish' | 'generic';
export type PlaymeshRuntimeBundlePresence = 'none' | 'full';
export type PlaymeshRuntimeActivation = 'inactive' | 'active';
export type PlaymeshRuntimePresentation = 'game' | 'diagnostic';
export type PlaymeshRuntimeManifestMode = 'solo' | 'multiplayer' | 'official';
export type PlaymeshRuntimePlanWarning = 'multiplayer_scan_unknown';
export type PlaymeshRuntimePlan = {|
  target: PlaymeshRuntimeTarget,
  bundlePresence: PlaymeshRuntimeBundlePresence,
  runtimeActivation: PlaymeshRuntimeActivation,
  presentation: PlaymeshRuntimePresentation,
  manifestMode: PlaymeshRuntimeManifestMode,
  connectCore: boolean,
  blockBeforeExport: boolean,
  warning: ?PlaymeshRuntimePlanWarning,
  reason: string,
|};
*/

const assertConfigStatus = (
  value /*: mixed */
) /*: PlaymeshRuntimeConfigStatus */ => {
  if (
    value !== 'online' &&
    value !== 'single' &&
    value !== 'missing' &&
    value !== 'invalid' &&
    value !== 'unavailable'
  ) {
    throw new Error('未知的 Playmesh 项目配置状态。');
  }
  return value;
};

const assertScanActivation = (
  value /*: mixed */
) /*: PlaymeshRuntimeScanActivation */ => {
  if (value !== 'enabled' && value !== 'disabled' && value !== 'unknown') {
    throw new Error('未知的 GDevelop 多人扫描状态。');
  }
  return value;
};

const assertTarget = (value /*: mixed */) /*: PlaymeshRuntimeTarget */ => {
  if (value !== 'preview' && value !== 'publish' && value !== 'generic') {
    throw new Error('未知的 GDevelop 运行目标。');
  }
  return value;
};

const createPlan = (
  {
    target,
    bundlePresence,
    runtimeActivation,
    presentation = 'game',
    manifestMode,
    blockBeforeExport,
    warning = null,
    reason,
  } /*: {|
  target: PlaymeshRuntimeTarget,
  bundlePresence: PlaymeshRuntimeBundlePresence,
  runtimeActivation: PlaymeshRuntimeActivation,
  presentation?: PlaymeshRuntimePresentation,
  manifestMode: PlaymeshRuntimeManifestMode,
  blockBeforeExport: boolean,
  warning?: ?PlaymeshRuntimePlanWarning,
  reason: string,
|} */
) /*: PlaymeshRuntimePlan */ => ({
  target,
  bundlePresence,
  runtimeActivation,
  presentation,
  manifestMode,
  connectCore: runtimeActivation === 'active',
  blockBeforeExport,
  warning,
  reason,
});

const conflictPlan = (
  target /*: PlaymeshRuntimeTarget */,
  reason /*: string */
) /*: PlaymeshRuntimePlan */ =>
  target === 'preview'
    ? createPlan({
        target,
        bundlePresence: 'full',
        runtimeActivation: 'inactive',
        presentation: 'game',
        manifestMode: 'solo',
        blockBeforeExport: false,
        reason,
      })
    : createPlan({
        target,
        bundlePresence: 'full',
        runtimeActivation: 'inactive',
        manifestMode: 'solo',
        blockBeforeExport: true,
        reason,
      });

export const resolveRuntimePlan = (
  configStatusValue /*: mixed */,
  scanActivationValue /*: mixed */,
  targetValue /*: mixed */
) /*: PlaymeshRuntimePlan */ => {
  const configStatus = assertConfigStatus(configStatusValue);
  const scanActivation = assertScanActivation(scanActivationValue);
  const target = assertTarget(targetValue);

  // 官方通用导出是不可穿透边界，配置与扫描结果均不能改变它。
  if (target === 'generic') {
    return createPlan({
      target,
      bundlePresence: 'none',
      runtimeActivation: 'inactive',
      manifestMode: 'official',
      blockBeforeExport: false,
      reason: 'generic_official_export',
    });
  }

  if (configStatus === 'online') {
    return createPlan({
      target,
      bundlePresence: 'full',
      runtimeActivation: 'active',
      manifestMode: 'multiplayer',
      blockBeforeExport: false,
      reason: 'explicit_online',
    });
  }

  // 损坏和不可达不能采用扫描结果，统一按 missing+unknown 处理并禁止连接 Core。
  if (configStatus === 'invalid' || configStatus === 'unavailable') {
    return conflictPlan(target, 'unsafe_config_status');
  }

  if (configStatus === 'single') {
    if (scanActivation === 'enabled') {
      return conflictPlan(target, 'explicit_single_scan_enabled');
    }
    return createPlan({
      target,
      bundlePresence: 'full',
      runtimeActivation: 'inactive',
      manifestMode: 'solo',
      blockBeforeExport: false,
      warning: scanActivation === 'unknown' ? 'multiplayer_scan_unknown' : null,
      reason:
        scanActivation === 'unknown'
          ? 'explicit_single_scan_unknown'
          : 'explicit_single_scan_disabled',
    });
  }

  if (scanActivation === 'disabled') {
    return createPlan({
      target,
      bundlePresence: 'full',
      runtimeActivation: 'inactive',
      manifestMode: 'solo',
      blockBeforeExport: false,
      reason: 'legacy_missing_scan_disabled',
    });
  }
  return conflictPlan(
    target,
    scanActivation === 'enabled'
      ? 'legacy_missing_scan_enabled'
      : 'legacy_missing_scan_unknown'
  );
};
