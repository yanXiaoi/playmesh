abstract interface class LocalAppSdkServer {
  Uri get scriptUri;

  Future<void> close();
}
