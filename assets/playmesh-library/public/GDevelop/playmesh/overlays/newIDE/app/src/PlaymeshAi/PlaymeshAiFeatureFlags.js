// @flow

const FEATURE_POLICY_FORMAT_VERSION = '1.0.0';
const EVENTS_PATH_TEMPLATE =
  '/dev/api/gdevelop/projects/{gameId}/ai/editor-sessions/' +
  '{editorSessionId}/events';

// The Developer Mode session bootstrap is the only authority. Missing,
// malformed, or stale bootstraps fail closed without a second build-time flag.
export const getIsPlaymeshAiEnabled = (): boolean => {
  const browserGlobal =
    typeof window === 'undefined' ? null : (window /*: any */);
  const policy = browserGlobal
    ? browserGlobal.__PLAYMESH_GDEVELOP_AI_FEATURE_POLICY__
    : null;
  if (!policy || typeof policy !== 'object' || Array.isArray(policy)) {
    return false;
  }
  const policyRecord /*: any */ = policy;
  const keys = Object.keys(policyRecord).sort();
  if (
    keys.join(',') !== 'enabled,eventsPathTemplate,formatVersion' ||
    policyRecord.formatVersion !== FEATURE_POLICY_FORMAT_VERSION ||
    policyRecord.eventsPathTemplate !== EVENTS_PATH_TEMPLATE
  ) {
    return false;
  }
  return policyRecord.enabled === true;
};

export default getIsPlaymeshAiEnabled;
