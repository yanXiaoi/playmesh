part of '../../sdk_feature_registry.dart';

/// 性能指标由 App SDK 在当前页面内保存和渲染。
///
/// Game SDK 只负责复用受控 Session 传输发送延迟探针；它不会把 FPS 或 RTT
/// 上报给 Dart，也不会维护第二份性能状态。
const gamePerformanceSdkSource = SdkSourceFragment(
  id: 'game.performance-transport',
  target: SdkSourceTarget.game,
  order: 50,
  typeScript: r'''
  function configureClientPerformance() {
    appInternalRuntime.configureRuntimePerformance?.({
      multiplayer: Boolean(bootstrap?.session),
      sendLatencyProbe(payload) {
        return post("performance.ping", payload);
      },
    });
  }

  function startLatencyProbes() {
    configureClientPerformance();
  }

  function stopLatencyProbes() {
    appInternalRuntime.configureRuntimePerformance?.({ multiplayer: false });
  }

  function handleLatencyPong(payload) {
    appInternalRuntime.recordRuntimeLatencyPong?.(payload);
  }

''',
);

final class _GamePerformanceTransportFeature implements _GameSdkCommandFeature {
  @override
  SdkSourceFragment get source => gamePerformanceSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('4.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {'performance.ping', 'performance.pong'};

  @override
  Future<SdkCommandExecution> execute(
    GameSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    switch (command.name) {
      case 'performance.ping':
        final connection = context.connection;
        if (connection == null) {
          throw const FormatException('单机模式不支持 performance.ping');
        }
        connection.submitLatencyProbe(command.payload);
        return const SdkCommandResult();
      case 'performance.pong':
        final connection = context.connection;
        if (connection == null) {
          throw const FormatException('单机模式不支持 performance.pong');
        }
        connection.submitLatencyResult(
          targetPlayerId: sdkRequiredString(command.raw, 'targetPlayerId'),
          probe: command.payload,
        );
        return const SdkCommandResult();
    }
    throw StateError('未注册的性能传输命令: ${command.name}');
  }
}
