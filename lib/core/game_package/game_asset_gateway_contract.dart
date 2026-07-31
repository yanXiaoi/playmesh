abstract interface class GameAssetGateway {
  /// WebView 的最终入口；路径指向本地网关，查询参数保留游戏入口声明。
  Uri get entryUri;

  Future<void> close();
}
