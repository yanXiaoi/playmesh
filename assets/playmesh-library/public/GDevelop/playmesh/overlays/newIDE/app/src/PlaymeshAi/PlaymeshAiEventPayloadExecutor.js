// @flow

import {
  addMissingObjectBehaviors,
  addObjectUndeclaredVariables,
  addUndeclaredVariables,
  applyEventsChanges,
} from '../EditorFunctions/ApplyEventsChanges';
import { PlaymeshAiLocalToolError } from './PlaymeshAiLocalToolWrappers';
import { getPlaymeshAiEventPayloadValidationError } from './PlaymeshAiProtocol';
/*::
import type { PlaymeshAiEventChange } from './PlaymeshAiProtocol';
import type { AiGeneratedEventChange } from '../Utils/GDevelopServices/Generation';
import type {
  PlaymeshAiEventPayloadContext,
  PlaymeshAiLocalToolExecution,
} from './PlaymeshAiLocalToolWrappers';
*/

const fail = (code /*: string */) /*: empty */ => {
  throw new PlaymeshAiLocalToolError(code, true);
};

/**
 * The Gateway validates the official DTO shape and the browser applies the
 * changes through GDevelop's pinned implementation. The official result is
 * returned unchanged: partial application and missing-resource diagnostics
 * are not converted into Playmesh-only failures.
 */
export const applyPlaymeshAiEventPayload = async ({
  call,
  project,
  eventPayload,
  runnerOptions,
} /*: PlaymeshAiEventPayloadContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
  const validationError = getPlaymeshAiEventPayloadValidationError(
    eventPayload,
    call.arguments.scene_name
  );
  if (validationError) fail(validationError);
  if (!project.hasLayoutNamed(eventPayload.sceneName)) {
    fail('event_payload_scene_missing');
  }
  const changes = eventPayload.changes;
  const officialChanges /*: Array<AiGeneratedEventChange> */ = changes.map(
    (change /*: PlaymeshAiEventChange */) /*: AiGeneratedEventChange */ =>
      ({
        ...change,
        generatedEvents:
          change.generatedEvents == null ? null : change.generatedEvents,
        operationTargetEvent:
          change.operationTargetEvent == null
            ? null
            : change.operationTargetEvent,
        isEventsJsonValid:
          change.isEventsJsonValid == null
            ? null
            : change.isEventsJsonValid,
        areEventsValid:
          change.areEventsValid == null ? null : change.areEventsValid,
        extensionNames:
          change.extensionNames == null ? null : change.extensionNames,
      })
  );
  const scene = project.getLayout(eventPayload.sceneName);
  changes.forEach(change => {
    addUndeclaredVariables({
      project,
      scene,
      undeclaredVariables: change.undeclaredVariables,
    });
    Object.keys(change.undeclaredObjectVariables).forEach(objectName => {
      addObjectUndeclaredVariables({
        project,
        scene,
        objectName,
        undeclaredVariables: change.undeclaredObjectVariables[objectName],
      });
    });
    Object.keys(change.missingObjectBehaviors).forEach(objectName => {
      addMissingObjectBehaviors({
        project,
        scene,
        objectName,
        missingBehaviors: change.missingObjectBehaviors[objectName],
      });
    });
  });
  // The pinned official applier and refresh callback own their failures from
  // this point. Let their diagnostics travel through the executor unchanged.
  const applied = applyEventsChanges(
    project,
    scene.getEvents(),
    officialChanges,
    call.callId
  );
  if (applied.applied > 0) {
    runnerOptions.onSceneEventsModifiedOutsideEditor({
      scene,
      newOrChangedAiGeneratedEventIds: new Set([call.callId]),
    });
  }
  return {
    result: {
      status: 'finished',
      call_id: call.callId,
      success: true,
      output: applied,
      ...(applied.applied > 0 ? { didModifyProject: true } : {}),
    },
    createdProject: null,
    createdSceneNames: [],
  };
};

export default applyPlaymeshAiEventPayload;
