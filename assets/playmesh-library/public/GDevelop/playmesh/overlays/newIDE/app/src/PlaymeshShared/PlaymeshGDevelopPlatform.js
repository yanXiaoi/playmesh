// @flow

// libGD keeps the actual registration flag in native static state. Keep every
// WebIDE caller behind this module singleton too, because calling the native
// initializer twice emits an error even though the second call is ignored.
const initializedInstances /*: WeakSet<Object> */ = new WeakSet();

export const ensureGDevelopJsPlatformIsRegistered = (
  gd /*: libGDevelop */
) /*: void */ => {
  if (initializedInstances.has(gd)) return;
  const runtime /*: any */ = gd;
  if (!runtime || typeof runtime.initializePlatforms !== 'function') {
    throw new Error('GDevelop JS platform initialization is unavailable.');
  }
  runtime.initializePlatforms();
  initializedInstances.add(gd);
};
