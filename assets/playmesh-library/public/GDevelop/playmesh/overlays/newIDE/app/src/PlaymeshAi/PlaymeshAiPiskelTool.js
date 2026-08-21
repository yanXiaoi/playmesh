// @flow

import { convertBlobToDataURL } from '../Utils/BlobDownloader';
import { addAnimationFrame } from '../ObjectEditor/Editors/SpriteEditor/SpritesList';
import { getFirstAnimationFrame } from '../ObjectEditor/Editors/SpriteEditor/Utils/SpriteObjectHelper';
import { runPlaymeshAiPiskelImport } from './PlaymeshAiPiskelRunner';
import { writePlaymeshAiExternalEditorOutput } from './PlaymeshAiExternalEditorResourceWriter';
const gd /*: libGDevelop */ = global.gd;
/*::
import type {
  PlaymeshAiCall,
  PlaymeshAiObject,
  PlaymeshAiStagedResource,
} from './PlaymeshAiProtocol';
import type {
  PlaymeshAiEditorFunctionExecution,
  PlaymeshAiEditorFunctionWrapperContext,
  PlaymeshAiEditorFunctionWrappers,
} from './PlaymeshAiEditorFunctionTypes';
import type {
  PlaymeshAiPiskelImportKind,
  PlaymeshAiPiskelImportOptions,
  PlaymeshAiPiskelOutput,
} from './PlaymeshAiPiskelRunner';
import type { ExternalEditorOutput } from '../ResourcesList/ResourceExternalEditor';

type PlaymeshAiPiskelToolOptions = {|
  stagedResource?: PlaymeshAiStagedResource,
  beforeProjectMutation?: () => void,
  onFetchNewlyAddedResources?: () => Promise<void>,
  onNewResourcesAdded?: () => void,
  runPiskelImport?: PlaymeshAiPiskelImportOptions =>
    Promise<PlaymeshAiPiskelOutput>,
|};
*/

class PlaymeshAiPiskelToolError extends Error {
  /*:: code: string; */

  constructor(code /*: string */) {
    super('The bundled Piskel AI tool could not be completed.');
    this.name = 'PlaymeshAiPiskelToolError';
    this.code = code;
  }
}

const finished = ({
  call,
  output,
} /*: {|
  call: PlaymeshAiCall,
  output: PlaymeshAiObject,
|} */) /*: PlaymeshAiEditorFunctionExecution */ => ({
  result: {
    status: 'finished',
    call_id: call.callId,
    success: true,
    output,
    didModifyProject: true,
  },
  createdProject: null,
  createdSceneNames: [],
  transientObjectUrls: [],
});

const findSpriteObject = ({
  project,
  sceneName,
  objectName,
  targetObjectScope,
} /*: {|
  project: gdProject,
  sceneName: string,
  objectName: string,
  targetObjectScope: 'scene' | 'global',
|} */) => {
  if (!project.hasLayoutNamed(sceneName)) {
    throw new PlaymeshAiPiskelToolError('piskel_scene_not_found');
  }
  const scene = project.getLayout(sceneName);
  const objects =
    targetObjectScope === 'global'
      ? project.getObjects()
      : scene.getObjects();
  const object = objects.hasObjectNamed(objectName)
    ? objects.getObject(objectName)
    : null;
  if (!object) {
    throw new PlaymeshAiPiskelToolError('piskel_object_not_found');
  }
  if (object.getType() !== 'Sprite') {
    throw new PlaymeshAiPiskelToolError('piskel_object_not_sprite');
  }
  return { object, scene };
};

const addPiskelAnimation = ({
  object,
  animationName,
  editResult,
  fps,
  looping,
  project,
} /*: {|
  object: gdObject,
  animationName: string,
  editResult: any,
  fps: number,
  looping: boolean,
  project: gdProject,
|} */) /*: number */ => {
  const spriteConfiguration = gd.asSpriteConfiguration(
    object.getConfiguration()
  );
  const animations = spriteConfiguration.getAnimations();
  const animation = new gd.Animation();
  try {
    animation.setName(animationName);
    animation.setDirectionsCount(1);
    const direction = animation.getDirection(0);
    direction.setTimeBetweenFrames(1 / fps);
    direction.setLoop(looping);

    const firstSprite = getFirstAnimationFrame(animations);
    const onSpriteAdded = (sprite /*: gdSprite */) => {
      if (!animations.adaptCollisionMaskAutomatically() || !firstSprite) {
        return;
      }
      sprite.setFullImageCollisionMask(
        firstSprite.isFullImageCollisionMask()
      );
      sprite.setCustomCollisionMask(firstSprite.getCustomCollisionMask());
    };
    const resourcesManager = project.getResourcesManager();
    editResult.resources.forEach(({ name }) => {
      addAnimationFrame(
        animations,
        direction,
        resourcesManager.getResource(name),
        onSpriteAdded
      );
    });
    if (editResult.newMetadata) {
      direction.setMetadata(JSON.stringify(editResult.newMetadata));
    }
    animations.addAnimation(animation);
    return animations.getAnimationsCount() - 1;
  } finally {
    animation.delete();
  }
};

export const createPlaymeshAiPiskelToolWrappers = ({
  stagedResource,
  beforeProjectMutation = () => {},
  onFetchNewlyAddedResources = async () => {},
  onNewResourcesAdded = () => {},
  runPiskelImport = runPlaymeshAiPiskelImport,
} /*: PlaymeshAiPiskelToolOptions */ = {}) /*: PlaymeshAiEditorFunctionWrappers */ => {
  const importAnimation = (
    kind /*: PlaymeshAiPiskelImportKind */
  ) => async ({
    call,
    project,
    runnerOptions,
  } /*: PlaymeshAiEditorFunctionWrapperContext */) => {
    if (!stagedResource) {
      throw new PlaymeshAiPiskelToolError('staged_resource_unavailable');
    }

    const animationName /*: string */ = (call.arguments
      .animation_name /*: any */);
    const piskelOutput = await runPiskelImport({
      kind,
      dataUrl: await convertBlobToDataURL(stagedResource.blob),
      name: animationName,
      frameWidth: (call.arguments.frame_width /*: any */),
      frameHeight: (call.arguments.frame_height /*: any */),
      frameOffsetX: (call.arguments.frame_offset_x /*: any */) || 0,
      frameOffsetY: (call.arguments.frame_offset_y /*: any */) || 0,
    });
    beforeProjectMutation();
    const { object, scene } = findSpriteObject({
      project,
      sceneName: (call.arguments.scene_name /*: any */),
      objectName: (call.arguments.object_name /*: any */),
      targetObjectScope: (call.arguments.target_object_scope /*: any */),
    });
    const externalEditorOutput /*: ExternalEditorOutput */ = {
      // The runner produces the official external-editor resource shape. The
      // cast bridges Flow's invariant Array type across the module boundary.
      resources: (piskelOutput.resources /*: any */),
      externalEditorData: piskelOutput.externalEditorData,
      baseNameForNewResources: piskelOutput.baseNameForNewResources,
    };
    const editResult = await writePlaymeshAiExternalEditorOutput({
      project,
      externalEditorOutput,
      resourceKind: 'image',
      metadataKey: 'pskl',
      onFetchNewlyAddedResources,
      onNewResourcesAdded,
    });
    const fps /*: number */ =
      (call.arguments.fps /*: any */) || piskelOutput.fps;
    const looping = call.arguments.looping !== false;
    const animationIndex = addPiskelAnimation({
      object,
      animationName,
      editResult,
      fps,
      looping,
      project,
    });
    runnerOptions.onObjectsModifiedOutsideEditor({
      scene,
      isNewObjectTypeUsed: false,
    });
    return finished({
      call,
      output: {
        scene_name: call.arguments.scene_name,
        object_name: call.arguments.object_name,
        target_object_scope: call.arguments.target_object_scope,
        animation_name: animationName,
        animation_index: animationIndex,
        frame_resource_names: editResult.resources.map(({ name }) => name),
        frame_count: editResult.resources.length,
        fps,
        looping,
        importer: 'piskel-5.5.228',
      },
    });
  };

  return {
    import_sprite_sheet_animation: importAnimation('spritesheet'),
    import_gif_animation: importAnimation('gif'),
  };
};

export default createPlaymeshAiPiskelToolWrappers;
