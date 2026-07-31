import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_media_adapter.dart';

abstract interface class WebRtcAppMediaDriver {
  bool get isAvailable;

  Future<AppMediaJson> createSource(AppMediaSourceRequest request);

  Future<AppMediaJson> open(String sourceId, AppMediaJson offer);

  Future<void> close(String sessionId);

  Future<void> releaseSource(String sourceId);

  Future<AppMediaJson> test(Duration timeout);

  Future<void> dispose();
}

final class NativeWebRtcAppMediaDriver implements WebRtcAppMediaDriver {
  const NativeWebRtcAppMediaDriver();

  static const MethodChannel _channel = MethodChannel(
    'playmesh/app_media/webrtc',
  );

  @override
  bool get isAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<AppMediaJson> createSource(AppMediaSourceRequest request) async {
    final result = await _channel
        .invokeMapMethod<String, Object?>('createSource', {
          'producer': request.producer,
          'kind': request.kind,
          'sourceOptions': request.sourceOptions,
          'adapterOptions': request.adapterOptions,
        });
    if (result == null) throw StateError('Android WebRTC 没有返回媒体源');
    return result;
  }

  @override
  Future<AppMediaJson> open(String sourceId, AppMediaJson offer) async {
    final result = await _channel.invokeMapMethod<String, Object?>('open', {
      'sourceId': sourceId,
      'offer': offer,
    });
    if (result == null) throw StateError('Android WebRTC 没有返回媒体会话');
    return result;
  }

  @override
  Future<void> close(String sessionId) =>
      _channel.invokeMethod<void>('close', {'sessionId': sessionId});

  @override
  Future<void> releaseSource(String sourceId) =>
      _channel.invokeMethod<void>('releaseSource', {'sourceId': sourceId});

  @override
  Future<AppMediaJson> test(Duration timeout) async {
    final result = await _channel.invokeMapMethod<String, Object?>('test', {
      'timeoutMs': timeout.inMilliseconds,
    });
    return result ?? const <String, Object?>{};
  }

  @override
  Future<void> dispose() async {
    try {
      await _channel.invokeMethod<void>('dispose');
    } on MissingPluginException {
      // 非 Android 测试宿主没有原生媒体适配器。
    } on FlutterError {
      // 未初始化 Flutter Binding 的纯 Dart 测试同样没有原生通道。
    }
  }
}

/// WebRTC 只是可注册媒体协议之一；公共运行时不会对它增加条件分支。
final class WebRtcAppMediaAdapter implements AppMediaAdapter {
  WebRtcAppMediaAdapter({WebRtcAppMediaDriver? driver})
    : _driver = driver ?? const NativeWebRtcAppMediaDriver();

  final WebRtcAppMediaDriver _driver;

  @override
  String get protocol => 'webrtc';

  @override
  int get priority => 100;

  @override
  bool get isAvailable => _driver.isAvailable;

  @override
  bool supportsProducer(String producer, String kind) =>
      producer == 'sensor.pose6d' && kind == 'video';

  @override
  Future<AppMediaAdapterSource> createSource(
    AppMediaSourceRequest request,
  ) async {
    final result = await _driver.createSource(request);
    final id = result['sourceId'];
    if (id is! String || id.isEmpty) {
      throw StateError('Android WebRTC 返回的 sourceId 无效');
    }
    final metadata = <String, Object?>{
      for (final entry in result.entries)
        if (entry.key != 'sourceId') entry.key: entry.value,
    };
    return AppMediaAdapterSource(id: id, metadata: Map.unmodifiable(metadata));
  }

  @override
  Future<AppMediaAdapterSession> open(
    AppMediaAdapterSource source,
    AppMediaJson adapterOptions,
  ) async {
    final offer = adapterOptions['offer'];
    if (offer is! Map) {
      throw const FormatException('WebRTC adapterOptions.offer 必须是对象');
    }
    final result = await _driver.open(
      source.id,
      Map<String, Object?>.from(offer),
    );
    final sessionId = result['sessionId'];
    final answer = result['answer'];
    if (sessionId is! String || sessionId.isEmpty || answer is! Map) {
      throw StateError('Android WebRTC 返回的媒体会话无效');
    }
    return AppMediaAdapterSession(
      id: sessionId,
      answer: Map<String, Object?>.from(answer),
    );
  }

  @override
  Future<void> close(String sessionId) => _driver.close(sessionId);

  @override
  Future<void> releaseSource(String sourceId) =>
      _driver.releaseSource(sourceId);

  @override
  Future<AppMediaJson> test(Duration timeout) => _driver.test(timeout);

  @override
  Future<void> dispose() => _driver.dispose();
}
