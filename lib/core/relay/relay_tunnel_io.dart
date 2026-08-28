import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, debugPrintStack;
import 'package:http/http.dart' as http;

import '../game_web/local_tunnel_gateway_contract.dart';
import 'relay_tunnel_contract.dart';

const _controlTimeout = Duration(seconds: 15);
int _controlSequence = 0;

Future<RelayHostSession> startRelayHostSession({
  required Uri coreBaseUri,
  required String sessionId,
  required Uri serverBaseUri,
  required String sourceToken,
  required String hostPath,
  required String clientPath,
  required Uri authorityWebBaseUri,
  required Uri authorityCoreBaseUri,
  required Uri authorityEntryUri,
  required int maxConnectionsPerTunnel,
}) async {
  final snapshot =
      await _post(coreBaseUri.resolve('v1/relay/host'), <String, Object?>{
        'serverBaseUrl': serverBaseUri.toString(),
        'sessionId': sessionId,
        'sourceToken': sourceToken,
        'hostPath': hostPath,
        'clientPath': clientPath,
        'authorityWebBaseUri': authorityWebBaseUri.toString(),
        'authorityCoreBaseUri': authorityCoreBaseUri.toString(),
        'authorityEntryUri': authorityEntryUri.toString(),
        'maxPeers': maxConnectionsPerTunnel,
      });
  return _CoreRelayHostSession(coreBaseUri: coreBaseUri, snapshot: snapshot)
    ..start();
}

Future<RelayClientSession> startRelayClientSession({
  required Uri coreBaseUri,
  required Uri invitationUri,
}) async {
  final snapshot = await _post(
    coreBaseUri.resolve('v1/relay/client'),
    <String, Object?>{'invitationUri': invitationUri.toString()},
  );
  return _CoreRelayClientSession(coreBaseUri: coreBaseUri, snapshot: snapshot);
}

class _CoreRelayHostSession implements RelayHostSession {
  _CoreRelayHostSession({required this.coreBaseUri, required this.snapshot})
    : _joinUri = Uri.parse(_requiredString(snapshot, 'joinUri')),
      _expiresAt = DateTime.parse(
        _requiredString(snapshot, 'expiresAt'),
      ).toUtc(),
      _connectionCount = _requiredInt(snapshot, 'connectionCount');

  final Uri coreBaseUri;
  final Map<String, Object?> snapshot;
  final Uri _joinUri;
  final DateTime _expiresAt;
  final StreamController<RelayConnectionStatus> _statuses =
      StreamController<RelayConnectionStatus>.broadcast(sync: true);
  Timer? _pollTimer;
  RelayConnectionStatus _status = RelayConnectionStatus.connected;
  int _connectionCount;
  bool _closed = false;

  String get _id => _requiredString(snapshot, 'id');

  Uri get _statusUri =>
      coreBaseUri.resolve('v1/relay/host/${Uri.encodeComponent(_id)}');

  void start() {
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_poll()),
    );
  }

  Future<void> _poll() async {
    if (_closed) return;
    try {
      final current = await _get(_statusUri);
      _connectionCount = _requiredInt(current, 'connectionCount');
      _setStatus(_parseStatus(_requiredString(current, 'status')));
    } on Object catch (error, stackTrace) {
      _logRelayException('host.status', error, stackTrace);
      _setStatus(RelayConnectionStatus.disconnected);
    }
  }

  void _setStatus(RelayConnectionStatus value) {
    if (_status == value) return;
    _status = value;
    if (!_statuses.isClosed) _statuses.add(value);
  }

  @override
  Uri get joinUri => _joinUri;

  @override
  RelayConnectionStatus get status => _status;

  @override
  Stream<RelayConnectionStatus> get statuses => _statuses.stream;

  @override
  int get connectionCount => _connectionCount;

  @override
  DateTime get expiresAt => _expiresAt;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _setStatus(RelayConnectionStatus.disconnected);
    try {
      await http
          .delete(_statusUri, headers: _controlMetadata().headers)
          .timeout(_controlTimeout);
    } on Object catch (error, stackTrace) {
      _logRelayException('host.close', error, stackTrace);
    }
    await _statuses.close();
  }
}

class _CoreRelayClientSession implements RelayClientSession {
  _CoreRelayClientSession({
    required this.coreBaseUri,
    required Map<String, Object?> snapshot,
  }) : _id = _requiredString(snapshot, 'id'),
       _connectionMode = _requiredString(snapshot, 'connectionMode'),
       webGateway = _CoreRelayClientGateway(
         localBaseUri: Uri.parse(_requiredString(snapshot, 'webBaseUri')),
         localEntryUri: Uri.parse(_requiredString(snapshot, 'localEntryUri')),
       ),
       coreGateway = _CoreLocalTunnelGateway(
         Uri.parse(_requiredString(snapshot, 'coreBaseUri')),
       );

  final Uri coreBaseUri;
  final String _id;
  final String _connectionMode;
  bool _closed = false;

  @override
  final RelayClientGateway webGateway;

  @override
  final LocalTunnelGateway coreGateway;

  @override
  String get connectionMode => _connectionMode;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      final metadata = _controlMetadata();
      await http
          .delete(
            coreBaseUri.resolve('v1/relay/client/${Uri.encodeComponent(_id)}'),
            headers: metadata.headers,
          )
          .timeout(_controlTimeout);
    } on Object catch (error, stackTrace) {
      _logRelayException('client.close', error, stackTrace);
    }
  }
}

class _CoreRelayClientGateway implements RelayClientGateway {
  const _CoreRelayClientGateway({
    required this.localBaseUri,
    required this.localEntryUri,
  });

  @override
  final Uri localBaseUri;

  @override
  final Uri localEntryUri;

  @override
  Future<void> close() async {}
}

class _CoreLocalTunnelGateway implements LocalTunnelGateway {
  const _CoreLocalTunnelGateway(this.localBaseUri);

  @override
  final Uri localBaseUri;

  @override
  Future<void> close() async {}
}

Future<Map<String, Object?>> _post(
  Uri endpoint,
  Map<String, Object?> body,
) async {
  final metadata = _controlMetadata();
  final response = await http
      .post(
        endpoint,
        headers: {
          ...metadata.headers,
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode(body),
      )
      .timeout(_controlTimeout);
  return _decodeResponse(response, metadata.requestId);
}

Future<Map<String, Object?>> _get(Uri endpoint) async {
  final metadata = _controlMetadata();
  final response = await http
      .get(endpoint, headers: metadata.headers)
      .timeout(_controlTimeout);
  return _decodeResponse(response, metadata.requestId);
}

Map<String, Object?> _decodeResponse(
  http.Response response,
  String expectedRequestId,
) {
  Object? decoded;
  try {
    decoded = jsonDecode(response.body);
  } on Object catch (error) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _RelayControlResponseException(
        statusCode: response.statusCode,
        requestId: expectedRequestId,
        body: response.body,
        parseError: error,
      );
    }
    throw FormatException(
      'Go Core WebRTC 响应不是有效 JSON: status=${response.statusCode} '
      'body=${response.body}',
      response.body,
    );
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    final message = decoded is Map ? decoded['message'] : null;
    throw _RelayControlResponseException(
      statusCode: response.statusCode,
      requestId: expectedRequestId,
      body: response.body,
      message: message is String ? message : null,
    );
  }
  if (decoded is! Map) {
    throw const FormatException('Go Core WebRTC 响应必须是对象');
  }
  final result = Map<String, Object?>.from(decoded);
  if (result['type'] != 'playmesh.webrtc-tunnel.snapshot' ||
      result['protocolVersion'] != relayCoreControlProtocolVersion ||
      result['requestId'] != expectedRequestId ||
      result['timestamp'] is! int) {
    throw FormatException(
      'Go Core WebRTC 响应元数据无效: status=${response.statusCode} '
      'body=${response.body}',
      response.body,
    );
  }
  return result;
}

final class _RelayControlResponseException implements Exception {
  const _RelayControlResponseException({
    required this.statusCode,
    required this.requestId,
    required this.body,
    this.message,
    this.parseError,
  });

  final int statusCode;
  final String requestId;
  final String body;
  final String? message;
  final Object? parseError;

  @override
  String toString() =>
      'RelayControlResponseException(statusCode=$statusCode, '
      'requestId=$requestId, message=$message, parseError=$parseError, '
      'body=$body)';
}

void _logRelayException(String operation, Object error, StackTrace stackTrace) {
  debugPrint('[Relay][error] operation=$operation error=$error');
  debugPrintStack(
    label: '[Relay][stack] operation=$operation',
    stackTrace: stackTrace,
  );
}

_ControlMetadata _controlMetadata() {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  _controlSequence = (_controlSequence + 1) & 0x7fffffff;
  return _ControlMetadata(
    'relay-$timestamp-${_controlSequence.toRadixString(36)}',
    timestamp,
  );
}

final class _ControlMetadata {
  const _ControlMetadata(this.requestId, this.timestamp);

  final String requestId;
  final int timestamp;

  Map<String, String> get headers => {
    'X-Playmesh-Control-Version': relayCoreControlProtocolVersion,
    'X-Playmesh-Request-ID': requestId,
    'X-Playmesh-Timestamp': timestamp.toString(),
  };
}

String _requiredString(Map<String, Object?> value, String name) {
  final field = value[name];
  if (field is! String || field.trim().isEmpty) {
    throw FormatException('Go Core WebRTC 响应缺少 $name');
  }
  return field;
}

int _requiredInt(Map<String, Object?> value, String name) {
  final field = value[name];
  if (field is! int || field < 0) {
    throw FormatException('Go Core WebRTC 响应缺少 $name');
  }
  return field;
}

RelayConnectionStatus _parseStatus(String value) => switch (value) {
  'connecting' => RelayConnectionStatus.connecting,
  'connected' => RelayConnectionStatus.connected,
  'retrying' => RelayConnectionStatus.retrying,
  _ => RelayConnectionStatus.disconnected,
};
