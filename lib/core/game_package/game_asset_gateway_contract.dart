abstract interface class GameAssetGateway {
  Uri get entryUri;

  Future<void> close();
}
