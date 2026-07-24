import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'game_session.dart';

typedef SessionChannelFactory = WebSocketChannel Function(Uri endpoint);

class GoCoreSessionClient {
  GoCoreSessionClient({
    required Uri baseUri,
    http.Client? httpClient,
    SessionChannelFactory? channelFactory,
  }) : baseUri = baseUri.replace(path: '/', query: null, fragment: null),
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _channelFactory = channelFactory ?? WebSocketChannel.connect;

  final Uri baseUri;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final SessionChannelFactory _channelFactory;

  Future<GameSessionConnection> create({
    required String gameId,
    required String displayMode,
    required int minPlayers,
    required int maxPlayers,
    required String nickname,
  }) async {
    final bootstrap = await _post('v1/sessions', {
      'gameId': gameId,
      'displayMode': displayMode,
      'minPlayers': minPlayers,
      'maxPlayers': maxPlayers,
      'nickname': nickname,
    });
    return _connect(bootstrap);
  }

  Future<GameSessionConnection> join({
    required String joinCode,
    required String nickname,
    String? shareToken,
    String? playerId,
  }) async {
    final bootstrap = await _post('v1/sessions/join', {
      'joinCode': joinCode,
      'nickname': nickname,
      'shareToken': ?shareToken,
      'playerId': ?playerId,
    });
    return _connect(bootstrap);
  }

  Future<GameSessionBootstrap> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    final response = await _httpClient.post(
      baseUri.resolve(path),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    final payload = _decodeResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GameSessionException.fromPayload(response.statusCode, payload);
    }
    return GameSessionBootstrap.fromJson(payload);
  }

  Future<GameSessionSnapshot> start(String sessionId, String token) async {
    final response = await _httpClient.post(
      baseUri.resolve('v1/sessions/$sessionId/start'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final payload = _decodeResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GameSessionException.fromPayload(response.statusCode, payload);
    }
    return GameSessionSnapshot.fromJson(payload);
  }

  Future<GameSessionSnapshot> reset(String sessionId, String token) async {
    final response = await _httpClient.post(
      baseUri.resolve('v1/sessions/$sessionId/reset'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final payload = _decodeResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GameSessionException.fromPayload(response.statusCode, payload);
    }
    return GameSessionSnapshot.fromJson(payload);
  }

  Future<GameSessionSnapshot> finish(String sessionId, String token) async {
    final response = await _httpClient.post(
      baseUri.resolve('v1/sessions/$sessionId/finish'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final payload = _decodeResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GameSessionException.fromPayload(response.statusCode, payload);
    }
    return GameSessionSnapshot.fromJson(payload);
  }

  Future<GameShareGrant> openShare(String sessionId, String token) async {
    final response = await _httpClient.post(
      baseUri.resolve('v1/sessions/$sessionId/share'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final payload = _decodeResponse(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GameSessionException.fromPayload(response.statusCode, payload);
    }
    return GameShareGrant(token: payload['token']! as String);
  }

  Future<void> closeShare(String sessionId, String token) async {
    final response = await _httpClient.delete(
      baseUri.resolve('v1/sessions/$sessionId/share'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 204) {
      throw GameSessionException.fromPayload(
        response.statusCode,
        _decodeResponse(response),
      );
    }
  }

  Future<GameSessionConnection> _connect(GameSessionBootstrap bootstrap) async {
    final httpUri = baseUri.resolve(bootstrap.webSocketPath);
    final endpoint = httpUri.replace(
      scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
      queryParameters: {'token': bootstrap.credential.token},
    );
    final channel = _channelFactory(endpoint);
    await channel.ready;
    final binaryHttpUri = baseUri.resolve(bootstrap.binaryWebSocketPath);
    final binaryEndpoint = binaryHttpUri.replace(
      scheme: binaryHttpUri.scheme == 'https' ? 'wss' : 'ws',
      queryParameters: {'token': bootstrap.credential.token},
    );
    return GameSessionConnection._(
      this,
      bootstrap,
      channel,
      endpoint: endpoint,
      channelFactory: _channelFactory,
      binaryEndpoint: binaryEndpoint,
    );
  }

  void close() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }
}

class GameSessionConnection {
  GameSessionConnection._(
    this._client,
    this.bootstrap,
    this._channel, {
    required this._endpoint,
    required this._channelFactory,
    required this.binaryEndpoint,
  }) {
    _listen(_channel!);
  }

  final GoCoreSessionClient _client;
  final Uri _endpoint;
  final SessionChannelFactory _channelFactory;
  WebSocketChannel? _channel;
  final GameSessionBootstrap bootstrap;
  final Uri binaryEndpoint;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  StreamSubscription<Object?>? _subscription;
  Future<void>? _reconnectOperation;
  final List<String> _outboundQueue = [];
  bool _closed = false;
  int _sequence = 0;
  late GameSessionSnapshot snapshot = bootstrap.session;

  Stream<Map<String, Object?>> get messages => _messages.stream;
  GameSessionPlayer get currentPlayer => bootstrap.credential.player;
  bool get isAuthority => currentPlayer.id == snapshot.authorityClientId;

  void submitAction(Map<String, Object?> action) {
    _send(type: 'game.action', payload: action);
  }

  void submitLatencyProbe(Map<String, Object?> probe) {
    _send(type: 'session.ping', payload: probe);
  }

  void submitLatencyResult({
    required String targetPlayerId,
    required Map<String, Object?> probe,
  }) {
    _send(
      type: 'authority.pong',
      payload: probe,
      targetPlayerIds: [targetPlayerId],
    );
  }

  void submitAuthorityResult({
    required List<String> targetPlayerIds,
    required Map<String, Object?> message,
  }) {
    if (!isAuthority) {
      throw const GameSessionException(
        statusCode: 403,
        code: 'not_authority',
        message: '当前玩家不是本局 Authority。',
      );
    }
    _send(
      type: 'authority.result',
      payload: message,
      targetPlayerIds: targetPlayerIds,
    );
  }

  Future<GameSessionSnapshot> start() async {
    snapshot = await _client.start(snapshot.id, bootstrap.credential.token);
    return snapshot;
  }

  Future<GameSessionSnapshot> reset() async {
    snapshot = await _client.reset(snapshot.id, bootstrap.credential.token);
    return snapshot;
  }

  Future<GameSessionSnapshot> finish() async {
    snapshot = await _client.finish(snapshot.id, bootstrap.credential.token);
    return snapshot;
  }

  Future<GameShareGrant> openShare() {
    return _client.openShare(snapshot.id, bootstrap.credential.token);
  }

  Future<void> closeShare() {
    return _client.closeShare(snapshot.id, bootstrap.credential.token);
  }

  void _send({
    required String type,
    required Map<String, Object?> payload,
    List<String>? targetPlayerIds,
  }) {
    _sequence += 1;
    final encoded = jsonEncode({
      'type': type,
      'sequence': _sequence,
      'targetPlayerIds': ?targetPlayerIds,
      'payload': payload,
    });
    final channel = _channel;
    if (channel == null) {
      _outboundQueue.add(encoded);
      return;
    }
    try {
      channel.sink.add(encoded);
    } on Object catch (error) {
      _outboundQueue.add(encoded);
      _handleDisconnect(channel, error);
    }
  }

  void _listen(WebSocketChannel channel) {
    _subscription = channel.stream.listen(
      _handleMessage,
      onError: (Object error, StackTrace stackTrace) {
        _handleDisconnect(channel, error);
      },
      onDone: () => _handleDisconnect(channel, '连接已关闭'),
    );
  }

  void _handleDisconnect(WebSocketChannel channel, Object error) {
    if (_closed || !identical(_channel, channel)) return;
    _channel = null;
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    _emitTransportStatus('disconnected', error: error);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _channel != null || _reconnectOperation != null) return;
    _reconnectOperation = _reconnect().whenComplete(() {
      _reconnectOperation = null;
      if (!_closed && _channel == null) _scheduleReconnect();
    });
  }

  Future<void> _reconnect() async {
    var attempt = 0;
    while (!_closed && _channel == null) {
      attempt += 1;
      if (attempt > 1) {
        final exponent = (attempt - 2).clamp(0, 5);
        final milliseconds = (250 * (1 << exponent)).clamp(250, 5000);
        await Future<void>.delayed(Duration(milliseconds: milliseconds));
      }
      if (_closed || _channel != null) return;
      _emitTransportStatus('reconnecting', attempt: attempt);
      WebSocketChannel? channel;
      try {
        channel = _channelFactory(_endpoint);
        await channel.ready;
        if (_closed) {
          await channel.sink.close();
          return;
        }
        _channel = channel;
        _listen(channel);
        while (_outboundQueue.isNotEmpty && identical(_channel, channel)) {
          channel.sink.add(_outboundQueue.removeAt(0));
        }
        if (!identical(_channel, channel)) continue;
        _emitTransportStatus('reconnected', attempt: attempt);
        return;
      } on Object catch (error) {
        if (identical(_channel, channel)) _channel = null;
        await channel?.sink.close();
        _emitTransportStatus('reconnecting', attempt: attempt, error: error);
      }
    }
  }

  void _emitTransportStatus(String state, {int? attempt, Object? error}) {
    if (_closed || _messages.isClosed) return;
    _messages.add({
      'type': 'transport.status',
      'transport': 'session',
      'state': state,
      'attempt': ?attempt,
      'error': ?error?.toString(),
    });
  }

  void _handleMessage(Object? raw) {
    try {
      final message = decodeSessionMessage(raw);
      final session = message['session'];
      if (session is Map) {
        snapshot = GameSessionSnapshot.fromJson(
          Map<String, Object?>.from(session),
        );
      }
      _messages.add(message);
    } on Object catch (error, stackTrace) {
      _messages.addError(error, stackTrace);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _outboundQueue.clear();
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final channel = _channel;
    _channel = null;
    await channel?.sink.close();
    if (!_messages.isClosed) await _messages.close();
  }
}

class GameShareGrant {
  const GameShareGrant({required this.token});

  final String token;
}

class GameSessionException implements Exception {
  const GameSessionException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  factory GameSessionException.fromPayload(
    int statusCode,
    Map<String, Object?> payload,
  ) {
    final rawError = payload['error'];
    final error = rawError is Map
        ? Map<String, Object?>.from(rawError)
        : const <String, Object?>{};
    return GameSessionException(
      statusCode: statusCode,
      code: error['code'] as String? ?? 'session_error',
      message: error['message'] as String? ?? '会话请求失败。',
    );
  }

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => 'GameSessionException($code: $message)';
}

Map<String, Object?> _decodeResponse(http.Response response) {
  final decoded = jsonDecode(response.body);
  if (decoded is! Map) {
    throw const FormatException('Go Core 会话响应根节点必须是对象');
  }
  return Map<String, Object?>.from(decoded);
}
