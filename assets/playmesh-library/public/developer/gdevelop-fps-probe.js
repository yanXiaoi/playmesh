(function installPlaymeshGDevelopFpsProbe(global) {
  'use strict';

  const probeKey = Symbol.for('playmesh.gdevelop.fps-probe.v1');
  const existingProbe = global[probeKey];
  if (existingProbe) {
    if (
      existingProbe.version === '1.0.0' &&
      typeof existingProbe.install === 'function'
    ) {
      try {
        existingProbe.install();
      } catch (_) {
        // A performance probe must never prevent the game from starting.
      }
    }
    return;
  }

  let installedPrototype = null;
  let originalRender = null;
  let wrappedRender = null;
  let reportWarningShown = false;

  const reportRenderedFrame = () => {
    const performanceApi = global.playmesh?.app?.performance;
    if (
      !performanceApi ||
      typeof performanceApi.reportFrame !== 'function'
    ) {
      return;
    }
    try {
      performanceApi.reportFrame();
    } catch (error) {
      if (reportWarningShown) return;
      reportWarningShown = true;
      global.console?.warn?.(
        'Playmesh GDevelop FPS probe could not report a rendered frame.',
        error
      );
    }
  };

  const install = () => {
    if (
      installedPrototype &&
      wrappedRender &&
      installedPrototype.render === wrappedRender
    ) {
      return true;
    }

    const runtimeScenePrototype = global.gdjs?.RuntimeScene?.prototype;
    if (
      !runtimeScenePrototype ||
      typeof runtimeScenePrototype.render !== 'function'
    ) {
      return false;
    }

    const candidateOriginalRender = runtimeScenePrototype.render;
    const candidateWrappedRender = function playmeshGDevelopRenderWithFpsProbe() {
      const result = Reflect.apply(candidateOriginalRender, this, arguments);
      reportRenderedFrame();
      return result;
    };
    try {
      runtimeScenePrototype.render = candidateWrappedRender;
    } catch (_) {
      return false;
    }
    if (runtimeScenePrototype.render !== candidateWrappedRender) return false;
    installedPrototype = runtimeScenePrototype;
    originalRender = candidateOriginalRender;
    wrappedRender = candidateWrappedRender;
    return true;
  };

  const dispose = () => {
    if (!installedPrototype || !originalRender || !wrappedRender) return true;
    if (installedPrototype.render !== wrappedRender) return false;
    try {
      installedPrototype.render = originalRender;
    } catch (_) {
      return false;
    }
    if (installedPrototype.render !== originalRender) return false;
    installedPrototype = null;
    originalRender = null;
    wrappedRender = null;
    return true;
  };

  const probe = Object.freeze({
    version: '1.0.0',
    install,
    dispose,
  });
  try {
    Object.defineProperty(global, probeKey, {
      configurable: true,
      enumerable: false,
      value: probe,
      writable: false,
    });
    global.addEventListener?.('pagehide', dispose);
    install();
  } catch (_) {
    // The probe is optional telemetry. Installation failures are fail-open.
  }
})(globalThis);
