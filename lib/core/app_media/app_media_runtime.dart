import 'dart:async';

import 'app_media_adapter.dart';
import 'app_media_adapter_registry.dart';

const String appMediaSourceType = 'playmesh.app.media-source';
const int appMediaSourceVersion = 1;

/// 能力插件只依赖本接口创建媒体源，不依赖 WebRTC 等具体传输协议。
abstract interface class AppMediaSourceBroker {
  Future<AppMediaJson> createSource({
    required String producer,
    required String kind,
    AppMediaJson sourceOptions,
    AppMediaJson adapterOptions,
  });

  Future<void> releaseSource(AppMediaJson source);
}

/// 公共媒体运行时。它负责选择适配器、签发不透明源、引用消费者并统一释放。
final class AppMediaRuntime implements AppMediaSourceBroker {
  AppMediaRuntime(Iterable<AppMediaAdapter> adapters)
    : this.withRegistry(AppMediaAdapterRegistry(adapters));

  AppMediaRuntime.withRegistry(this.registry);

  final AppMediaAdapterRegistry registry;
  final Map<String, _OpenMediaSource> _sources = {};
  final Map<String, _OpenMediaSession> _sessions = {};
  int _sourceSequence = 0;
  int _sessionSequence = 0;
  bool _disposed = false;

  List<String> get availableProtocols => registry.availableProtocols;

  @override
  Future<AppMediaJson> createSource({
    required String producer,
    required String kind,
    AppMediaJson sourceOptions = const <String, Object?>{},
    AppMediaJson adapterOptions = const <String, Object?>{},
  }) async {
    _ensureActive();
    if (producer.isEmpty) throw const FormatException('媒体 producer 不能为空');
    if (kind.isEmpty) throw const FormatException('媒体 kind 不能为空');
    final adapter = registry.select(producer: producer, kind: kind);
    if (adapter == null) {
      throw UnsupportedError('当前终端没有可处理 $producer/$kind 的媒体适配器');
    }
    final adapterSource = await adapter.createSource(
      AppMediaSourceRequest(
        producer: producer,
        kind: kind,
        sourceOptions: _freezeJsonMap(sourceOptions, 'sourceOptions'),
        adapterOptions: _freezeJsonMap(adapterOptions, 'adapterOptions'),
      ),
    );
    if (adapterSource.id.isEmpty) {
      throw StateError('${adapter.protocol} 媒体适配器返回了空源 ID');
    }
    const reservedFields = {
      'type',
      'version',
      'id',
      'kind',
      'protocol',
      'live',
    };
    final metadata = _freezeJsonMap(
      adapterSource.metadata,
      '${adapter.protocol}.metadata',
    );
    String? conflictingField;
    for (final field in metadata.keys) {
      if (reservedFields.contains(field)) {
        conflictingField = field;
        break;
      }
    }
    if (conflictingField != null) {
      await adapter.releaseSource(adapterSource.id);
      throw StateError(
        '${adapter.protocol} 媒体适配器 metadata 不能覆盖 $conflictingField',
      );
    }
    final publicId =
        'media-source-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_sourceSequence}';
    final descriptor = <String, Object?>{
      'type': appMediaSourceType,
      'version': appMediaSourceVersion,
      'id': publicId,
      'kind': kind,
      'protocol': adapter.protocol,
      'live': true,
      ...metadata,
    };
    _sources[publicId] = _OpenMediaSource(
      descriptor: _freezeJsonMap(descriptor, 'source'),
      adapter: adapter,
      adapterSource: adapterSource,
    );
    return _cloneJsonMap(descriptor);
  }

  Future<AppMediaJson> open(AppMediaJson payload) async {
    _ensureActive();
    final source = _requiredMap(payload, 'source');
    _validateSourceDescriptor(source);
    final publicSourceId = source['id']! as String;
    final openSource = _sources[publicSourceId];
    if (openSource == null || !_sameDescriptor(source, openSource.descriptor)) {
      throw StateError('媒体源不存在、已释放或不属于当前游戏页面');
    }
    final adapterOptions = _requiredMap(payload, 'adapterOptions');
    final adapterSession = await openSource.adapter.open(
      openSource.adapterSource,
      adapterOptions,
    );
    if (adapterSession.id.isEmpty) {
      throw StateError('${openSource.adapter.protocol} 媒体适配器返回了空会话 ID');
    }
    final AppMediaJson answer;
    try {
      answer = _freezeJsonMap(
        adapterSession.answer,
        '${openSource.adapter.protocol}.answer',
      );
    } on Object {
      await openSource.adapter.close(adapterSession.id);
      rethrow;
    }
    final publicSessionId =
        'media-session-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_sessionSequence}';
    _sessions[publicSessionId] = _OpenMediaSession(
      publicSourceId: publicSourceId,
      adapter: openSource.adapter,
      adapterSessionId: adapterSession.id,
    );
    return {
      'sessionId': publicSessionId,
      'source': _cloneJsonMap(openSource.descriptor),
      'protocol': openSource.adapter.protocol,
      'answer': _cloneJsonMap(answer),
    };
  }

  Future<void> close(AppMediaJson payload) async {
    final sessionId = _requiredString(payload, 'sessionId');
    final session = _sessions.remove(sessionId);
    if (session == null) return;
    await session.adapter.close(session.adapterSessionId);
  }

  @override
  Future<void> releaseSource(AppMediaJson source) async {
    if (_disposed) return;
    _validateSourceDescriptor(source);
    final publicSourceId = source['id']! as String;
    final openSource = _sources[publicSourceId];
    if (openSource == null) return;
    if (!_sameDescriptor(source, openSource.descriptor)) {
      throw StateError('媒体源描述符与当前页面签发记录不一致');
    }
    _sources.remove(publicSourceId);
    final sessionIds = _sessions.entries
        .where((entry) => entry.value.publicSourceId == publicSourceId)
        .map((entry) => entry.key)
        .toList(growable: false);
    final actions = <Future<void> Function()>[];
    for (final sessionId in sessionIds) {
      final session = _sessions.remove(sessionId);
      if (session != null) {
        actions.add(() => session.adapter.close(session.adapterSessionId));
      }
    }
    actions.add(
      () => openSource.adapter.releaseSource(openSource.adapterSource.id),
    );
    await _runCleanupActions(actions);
  }

  Future<void> reset() async {
    if (_disposed) return;
    await _cleanupOpenResources();
  }

  Future<void> _cleanupOpenResources() async {
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    final sources = _sources.values.toList(growable: false);
    _sources.clear();
    await _runCleanupActions([
      for (final session in sessions)
        () => session.adapter.close(session.adapterSessionId),
      for (final source in sources)
        () => source.adapter.releaseSource(source.adapterSource.id),
    ]);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _runCleanupActions([
      _cleanupOpenResources,
      for (final adapter in registry.adapters) adapter.dispose,
    ]);
  }

  Future<List<AppMediaJson>> test(Duration timeout) async {
    _ensureActive();
    final results = <AppMediaJson>[];
    for (final adapter in registry.adapters) {
      if (!adapter.isAvailable) {
        results.add({'protocol': adapter.protocol, 'available': false});
        continue;
      }
      try {
        final result = await adapter.test(timeout).timeout(timeout);
        results.add({
          'protocol': adapter.protocol,
          'available': true,
          ...result,
        });
      } on TimeoutException {
        results.add({
          'protocol': adapter.protocol,
          'available': true,
          'status': 'timeout',
        });
      }
    }
    return results;
  }

  void _ensureActive() {
    if (_disposed) throw StateError('媒体运行时已释放');
  }
}

final class _OpenMediaSource {
  const _OpenMediaSource({
    required this.descriptor,
    required this.adapter,
    required this.adapterSource,
  });

  final AppMediaJson descriptor;
  final AppMediaAdapter adapter;
  final AppMediaAdapterSource adapterSource;
}

final class _OpenMediaSession {
  const _OpenMediaSession({
    required this.publicSourceId,
    required this.adapter,
    required this.adapterSessionId,
  });

  final String publicSourceId;
  final AppMediaAdapter adapter;
  final String adapterSessionId;
}

void _validateSourceDescriptor(AppMediaJson source) {
  if (source['type'] != appMediaSourceType ||
      source['version'] != appMediaSourceVersion ||
      source['live'] != true) {
    throw const FormatException('媒体源描述符无效');
  }
  _requiredString(source, 'id');
  _requiredString(source, 'kind');
}

bool _sameDescriptor(AppMediaJson left, AppMediaJson right) {
  return _deepEquals(left, right);
}

bool _deepEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_deepEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!_deepEquals(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

String _requiredString(AppMediaJson value, String field) {
  final result = value[field];
  if (result is! String || result.isEmpty) {
    throw FormatException('$field 必须是非空字符串');
  }
  return result;
}

AppMediaJson _requiredMap(AppMediaJson value, String field) {
  final result = value[field];
  if (result is! Map) throw FormatException('$field 必须是对象');
  return Map<String, Object?>.from(result);
}

AppMediaJson _freezeJsonMap(AppMediaJson value, String field) {
  return Map<String, Object?>.unmodifiable({
    for (final entry in value.entries)
      entry.key: _freezeJsonValue(entry.value, '$field.${entry.key}'),
  });
}

Object? _freezeJsonValue(Object? value, String field) {
  if (value == null || value is bool || value is String) return value;
  if (value is num) {
    if (!value.isFinite) throw FormatException('$field 必须是有限数字');
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable([
      for (var index = 0; index < value.length; index += 1)
        _freezeJsonValue(value[index], '$field[$index]'),
    ]);
  }
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) throw FormatException('$field 的对象键必须是字符串');
      result[key] = _freezeJsonValue(entry.value, '$field.$key');
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  throw FormatException('$field 不是可传输的 JSON 值');
}

AppMediaJson _cloneJsonMap(AppMediaJson value) => {
  for (final entry in value.entries) entry.key: _cloneJsonValue(entry.value),
};

Object? _cloneJsonValue(Object? value) {
  if (value is List) {
    return value.map(_cloneJsonValue).toList(growable: true);
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key as String: _cloneJsonValue(entry.value),
    };
  }
  return value;
}

Future<void> _runCleanupActions(
  Iterable<Future<void> Function()> actions,
) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final action in actions) {
    try {
      await action();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}
