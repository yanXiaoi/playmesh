// @flow

export type PlaymeshPixiTextureAsset =
  | string
  | {|
      alias: string,
      src: string,
      loadParser: 'loadTextures',
    |};

const PLAYMESH_PIXI_BLOB_TEXTURE_ALIAS_PREFIX =
  'playmesh-blob-texture:';

/**
 * Pixi 7 chooses its Assets parser from the URL suffix before it fetches the
 * resource. Browser Blob URLs have no suffix, so their valid image MIME type
 * is never inspected unless the built-in texture parser is selected
 * explicitly.
 *
 * A Blob URL can already exist in Pixi's Resolver after the initial scene
 * render. Pixi 7 does not replace that existing resolver entry when
 * `Assets.load` later receives an object with the same `src`, which would drop
 * the explicit `loadParser` again during a resource reload. A stable, private
 * alias makes the hinted entry independent while keeping `src` unchanged for
 * Pixi's loader cache and unload lifecycle.
 *
 * Keep ordinary URLs on Pixi's official detection path and only provide this
 * descriptor for live, in-memory Blob URLs.
 */
export const getPlaymeshPixiTextureAsset = (
  url: string
): PlaymeshPixiTextureAsset =>
  url.startsWith('blob:')
    ? {
        alias: `${PLAYMESH_PIXI_BLOB_TEXTURE_ALIAS_PREFIX}${url}`,
        src: url,
        loadParser: 'loadTextures',
      }
    : url;
