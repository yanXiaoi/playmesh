import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

abstract interface class RuntimeSessionConnection {
  Uri get coreBase;
  Map<String, Object?> get snapshot;
  Map<String, Object?> get currentPlayer;
  Uri get binaryWebSocketUri;
  Stream<Map<String, Object?>> get messages;
  bool get isAuthority;

  void submit(
    String type,
    Map<String, Object?> payload, {
    List<String>? targets,
  });

  Future<Map<String, Object?>> start();
  Future<Map<String, Object?>> reset();
  Future<Map<String, Object?>> finish();
  Future<Map<String, Object?>> updateNickname(String nickname);
  Future<Map<String, Object?>> refreshSnapshot();
  void confirmAvatarWritten({required String playerId, required String sha256});
  void rejectAvatarWrite({required String playerId, required String sha256});
  Future<void> close();
}

final class RuntimeSession implements RuntimeSessionConnection {
  static const requestTimeout = Duration(seconds: 8);

  RuntimeSession._({
    required this.coreBase,
    required this.bootstrap,
    required this.snapshot,
    required this.player,
    required this.token,
    required this.webSocketUri,
    required this.binaryWebSocketUri,
    required this._channel,
    required this._client,
  }) {
    _subscription = _channel.stream.listen(
      _onMessage,
      onError: _messages.addError,
      onDone: _messages.close,
    );
  }

  static Future<RuntimeSession> create({
    required Uri coreBase,
    required String gameId,
    required String displayMode,
    required int minPlayers,
    required int maxPlayers,
    required String nickname,
  }) async {
    final client = http.Client();
    try {
      final response = await client
          .post(
            coreBase.resolve('v1/sessions'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'gameId': gameId,
              'displayMode': displayMode,
              'minPlayers': minPlayers,
              'maxPlayers': maxPlayers,
              'nickname': nickname,
            }),
          )
          .timeout(requestTimeout);
      final bootstrap = _responseObject(response);
      final session = _object(bootstrap, 'session');
      final credential = _object(bootstrap, 'credential');
      final player = _object(credential, 'player');
      final token = _string(credential, 'token');
      final webSocketUri = _socketUri(
        coreBase.resolve(_string(bootstrap, 'webSocketPath')),
        token,
      );
      final binaryWebSocketUri = _socketUri(
        coreBase.resolve(_string(bootstrap, 'binaryWebSocketPath')),
        token,
      );
      final channel = WebSocketChannel.connect(webSocketUri);
      await channel.ready.timeout(requestTimeout);
      return RuntimeSession._(
        coreBase: coreBase,
        bootstrap: bootstrap,
        snapshot: session,
        player: player,
        token: token,
        webSocketUri: webSocketUri,
        binaryWebSocketUri: binaryWebSocketUri,
        channel: channel,
        client: client,
      );
    } on Object {
      client.close();
      rethrow;
    }
  }

  @override
  final Uri coreBase;
  final Map<String, Object?> bootstrap;
  @override
  Map<String, Object?> snapshot;
  final Map<String, Object?> player;
  final String token;
  final Uri webSocketUri;
  @override
  final Uri binaryWebSocketUri;
  final WebSocketChannel _channel;
  final http.Client _client;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  late final StreamSubscription<Object?> _subscription;
  int _sequence = 0;
  String? _shareToken;
  bool _closed = false;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Map<String, Object?> get currentPlayer {
    final playerId = player['id'];
    final players = snapshot['players'];
    if (players is List) {
      for (final candidate in players) {
        if (candidate is Map && candidate['id'] == playerId) {
          return Map<String, Object?>.from(candidate);
        }
      }
    }
    return player;
  }

  @override
  bool get isAuthority => currentPlayer['id'] == snapshot['authorityClientId'];

  String get sessionId => _string(snapshot, 'id');

  String get joinCode => _string(snapshot, 'joinCode');

  String? get shareToken => _shareToken;

  @override
  void submit(
    String type,
    Map<String, Object?> payload, {
    List<String>? targets,
  }) {
    _channel.sink.add(
      jsonEncode({
        'type': type,
        'sequence': ++_sequence,
        'targetPlayerIds': ?targets,
        'payload': payload,
      }),
    );
  }

  @override
  void confirmAvatarWritten({
    required String playerId,
    required String sha256,
  }) {
    if (!isAuthority) throw StateError('当前页面不是 Authority');
    submit('platform.avatar.committed', {
      'playerId': playerId,
      'digest': sha256,
    });
  }

  @override
  void rejectAvatarWrite({required String playerId, required String sha256}) {
    if (!isAuthority) return;
    submit('platform.avatar.failed', {'playerId': playerId, 'digest': sha256});
  }

  @override
  Future<Map<String, Object?>> start() => _transition('start');
  @override
  Future<Map<String, Object?>> reset() => _transition('reset');
  @override
  Future<Map<String, Object?>> finish() => _transition('finish');

  @override
  Future<Map<String, Object?>> updateNickname(String nickname) async {
    final normalized = nickname.trim();
    if (normalized.isEmpty || normalized.runes.length > 32) {
      throw const FormatException('昵称必须为 1 至 32 个字符');
    }
    final expectedSessionId = sessionId;
    final expectedPlayerId = _string(currentPlayer, 'id');
    final response = await _client
        .patch(
          coreBase.resolve(
            'v1/sessions/${Uri.encodeComponent(expectedSessionId)}/players/me',
          ),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'nickname': normalized}),
        )
        .timeout(requestTimeout);
    final payload = _responseObject(response);
    final updatedSnapshot = _object(payload, 'session');
    final updatedPlayer = _object(payload, 'player');
    final snapshotPlayer = _findPlayer(updatedSnapshot, expectedPlayerId);
    if (updatedSnapshot['id'] != expectedSessionId ||
        updatedPlayer['id'] != expectedPlayerId ||
        updatedPlayer['nickname'] != normalized ||
        snapshotPlayer?['nickname'] != normalized) {
      throw const FormatException('昵称更新响应与当前会话不一致');
    }
    snapshot = updatedSnapshot;
    player
      ..clear()
      ..addAll(updatedPlayer);
    return currentPlayer;
  }

  @override
  Future<Map<String, Object?>> refreshSnapshot() async {
    final expectedSessionId = sessionId;
    final response = await _client
        .get(
          coreBase.resolve(
            'v1/sessions/${Uri.encodeComponent(expectedSessionId)}',
          ),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(requestTimeout);
    final updatedSnapshot = _responseObject(response);
    if (updatedSnapshot['id'] != expectedSessionId) {
      throw const FormatException('会话快照响应与当前会话不一致');
    }
    snapshot = updatedSnapshot;
    return snapshot;
  }

  Future<String> openShare() async {
    final response = await _client
        .post(
          coreBase.resolve('v1/sessions/${_string(snapshot, 'id')}/share'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(requestTimeout);
    final value = _string(_responseObject(response), 'token');
    _shareToken = value;
    return value;
  }

  Future<void> closeShare() async {
    if (_shareToken == null) return;
    final response = await _client
        .delete(
          coreBase.resolve('v1/sessions/$sessionId/share'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(requestTimeout);
    if (response.statusCode != 204) {
      _responseObject(response);
    }
    _shareToken = null;
  }

  Future<Map<String, Object?>> _transition(String operation) async {
    final response = await _client
        .post(
          coreBase.resolve('v1/sessions/${_string(snapshot, 'id')}/$operation'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(requestTimeout);
    snapshot = _responseObject(response);
    return snapshot;
  }

  void _onMessage(Object? raw) {
    try {
      if (raw is! String) throw const FormatException('Go Core 消息必须是文本');
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('Go Core 消息必须是对象');
      final message = Map<String, Object?>.from(decoded);
      if (message['session'] is Map) {
        snapshot = Map<String, Object?>.from(message['session']! as Map);
      }
      _messages.add(message);
    } on Object catch (error, stackTrace) {
      _messages.addError(error, stackTrace);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await closeShare();
    } on Object {
      // Runtime 关闭不能被撤销分享失败阻塞；Go Core 进程随后仍会终止。
    }
    await _subscription.cancel();
    await _channel.sink.close();
    if (!_messages.isClosed) await _messages.close();
    _client.close();
  }
}

Map<String, Object?> _responseObject(http.Response response) {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw RuntimeSessionRequestException(response.statusCode);
  }
  final decoded = jsonDecode(response.body);
  if (decoded is! Map) throw const FormatException('Go Core 响应必须是对象');
  final payload = Map<String, Object?>.from(decoded);
  return payload;
}

final class RuntimeSessionRequestException implements Exception {
  const RuntimeSessionRequestException(this.statusCode);

  final int statusCode;

  bool get isDefinitiveRejection => statusCode >= 400 && statusCode < 500;

  @override
  String toString() => 'Go Core 请求失败 ($statusCode)';
}

Map<String, Object?> _object(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! Map) throw FormatException('$key 必须是对象');
  return Map<String, Object?>.from(value);
}

String _string(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String || value.isEmpty) throw FormatException('$key 无效');
  return value;
}

Map<String, Object?>? _findPlayer(
  Map<String, Object?> snapshot,
  String playerId,
) {
  final players = snapshot['players'];
  if (players is! List) return null;
  for (final candidate in players) {
    if (candidate is Map && candidate['id'] == playerId) {
      return Map<String, Object?>.from(candidate);
    }
  }
  return null;
}

Uri _socketUri(Uri uri, String token) => uri.replace(
  scheme: uri.scheme == 'https' ? 'wss' : 'ws',
  queryParameters: {'token': token},
);
