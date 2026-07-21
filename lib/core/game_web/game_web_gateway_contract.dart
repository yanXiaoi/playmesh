abstract interface class GameWebGateway {
  int get port;

  Future<List<Uri>> shareLinks();

  Future<void> close();
}
