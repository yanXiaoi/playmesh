typedef AppMediaJson = Map<String, Object?>;

/// 媒体适配器创建源时收到的协议无关请求。
final class AppMediaSourceRequest {
  const AppMediaSourceRequest({
    required this.producer,
    required this.kind,
    required this.sourceOptions,
    this.adapterOptions = const <String, Object?>{},
  });

  final String producer;
  final String kind;
  final AppMediaJson sourceOptions;

  /// 公共层不读取本字段；被选中的适配器自行定义并校验其内容。
  final AppMediaJson adapterOptions;
}

/// 适配器私有的媒体源。公共 SDK 只会得到由运行时重新签发的 opaque descriptor。
final class AppMediaAdapterSource {
  const AppMediaAdapterSource({
    required this.id,
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final AppMediaJson metadata;
}

/// 适配器打开一个消费者后返回的私有会话及协议应答。
final class AppMediaAdapterSession {
  const AppMediaAdapterSession({required this.id, required this.answer});

  final String id;
  final AppMediaJson answer;
}

/// 一个具体媒体协议只实现本接口；公共媒体运行时不识别 WebRTC 等协议细节。
abstract interface class AppMediaAdapter {
  String get protocol;

  int get priority;

  bool get isAvailable;

  bool supportsProducer(String producer, String kind);

  Future<AppMediaAdapterSource> createSource(AppMediaSourceRequest request);

  Future<AppMediaAdapterSession> open(
    AppMediaAdapterSource source,
    AppMediaJson adapterOptions,
  );

  Future<void> close(String sessionId);

  Future<void> releaseSource(String sourceId);

  Future<AppMediaJson> test(Duration timeout);

  Future<void> dispose();
}
