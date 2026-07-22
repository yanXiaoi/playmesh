export interface PlaymeshCoreNativeModule {
  start(address: string): Promise<string>;
  stop(): Promise<void>;
}

declare const playmeshCore: PlaymeshCoreNativeModule;
export default playmeshCore;
