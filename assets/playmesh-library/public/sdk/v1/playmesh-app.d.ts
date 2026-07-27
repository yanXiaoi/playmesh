/// <reference path="./playmesh.d.ts" />

/** App WebView 自动注入的底层对象。游戏业务使用 playmesh.app。 */
declare const playmeshApp: PlaymeshAppApi;
interface Window { playmeshApp: PlaymeshAppApi; }
