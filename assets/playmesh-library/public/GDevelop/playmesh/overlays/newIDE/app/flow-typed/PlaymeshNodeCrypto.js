// @flow

// Only the Web Crypto surface used by PlaymeshCatalogRuntime.test.js is
// declared. The implementation remains Node's built-in `node:crypto` module.
declare module 'node:crypto' {
  declare export var webcrypto: {|
    +subtle: {|
      digest: (
        algorithm: string,
        data: ArrayBuffer | Uint8Array
      ) => Promise<ArrayBuffer>,
    |},
  |};
}
