import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/game_id.dart';
import '../relay/relay_tunnel.dart';
import 'game_invitation.dart';
import 'game_web_gateway_contract.dart';

const defaultGameInvitationInspectionTimeout = Duration(seconds: 5);
const maxGameInvitationInspectionResponseBytes = 4 * 1024;

typedef RelayClientGatewayFactory =
    Future<RelayClientGateway> Function({
      required Uri invitationUri,
      required RelayTarget target,
    });

enum GameInvitationInspectionFailure {
  invalidInvitation,
  invalidResponse,
  unavailable,
  timedOut,
  closed,
}

class GameInvitationInspectionException implements Exception {
  const GameInvitationInspectionException(this.failure);

  final GameInvitationInspectionFailure failure;

  @override
  String toString() => switch (failure) {
    GameInvitationInspectionFailure.invalidInvitation => '游戏邀请无效',
    GameInvitationInspectionFailure.invalidResponse => '游戏邀请响应无效',
    GameInvitationInspectionFailure.unavailable => '游戏邀请入口不可用',
    GameInvitationInspectionFailure.timedOut => '游戏邀请检查超时',
    GameInvitationInspectionFailure.closed => '游戏邀请检查服务已关闭',
  };
}

class InspectedGameInvitation {
  const InspectedGameInvitation({
    required this.invitation,
    required this.gameId,
    required this.gameName,
  });

  final GameInvitation invitation;
  final String gameId;
  final String gameName;
}

abstract interface class GameInvitationInspector {
  Future<InspectedGameInvitation> inspect(GameInvitation invitation);

  Future<void> close();
}

class DefaultGameInvitationInspector implements GameInvitationInspector {
  factory DefaultGameInvitationInspector({
    http.Client? httpClient,
    RelayClientGatewayFactory relayClientGatewayFactory =
        startRelayClientGateway,
    Duration timeout = defaultGameInvitationInspectionTimeout,
  }) => DefaultGameInvitationInspector._(
    httpClient ?? http.Client(),
    relayClientGatewayFactory,
    timeout,
  );

  DefaultGameInvitationInspector._(
    this._httpClient,
    this._relayClientGatewayFactory,
    this.timeout,
  ) {
    if (timeout.inMicroseconds <= 0) {
      throw ArgumentError.value(timeout, 'timeout', '必须大于零');
    }
  }

  final http.Client _httpClient;
  final RelayClientGatewayFactory _relayClientGatewayFactory;
  final Duration timeout;
  bool _closed = false;

  @override
  Future<InspectedGameInvitation> inspect(GameInvitation invitation) async {
    if (_closed) {
      throw const GameInvitationInspectionException(
        GameInvitationInspectionFailure.closed,
      );
    }
    RelayClientGateway? relayGateway;
    try {
      var requestInvitation = invitation;
      if (invitation.usesRelay) {
        relayGateway = await _relayClientGatewayFactory(
          invitationUri: invitation.entryUri,
          target: RelayTarget.web,
        );
        requestInvitation = GameInvitation.parse(
          relayGateway.localEntryUri.toString(),
        );
      }
      return await _inspectHttp(
        requestInvitation: requestInvitation,
        originalInvitation: invitation,
      );
    } on GameInvitationInspectionException {
      rethrow;
    } on FormatException {
      throw const GameInvitationInspectionException(
        GameInvitationInspectionFailure.invalidInvitation,
      );
    } on UnsupportedError {
      throw const GameInvitationInspectionException(
        GameInvitationInspectionFailure.unavailable,
      );
    } on Object {
      throw const GameInvitationInspectionException(
        GameInvitationInspectionFailure.unavailable,
      );
    } finally {
      // Relay 预检只借用现有 Web 回环；无论响应如何都不能把临时网关留给后续导航。
      try {
        await relayGateway?.close();
      } on Object {
        // 清理错误不得覆盖已经得到的受控检查结果，也不得泄露 Relay 凭据。
      }
    }
  }

  Future<InspectedGameInvitation> _inspectHttp({
    required GameInvitation requestInvitation,
    required GameInvitation originalInvitation,
  }) async {
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(
            'POST',
            requestInvitation.requestUri,
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll(const {
            'Accept': 'application/json',
            'Content-Type': 'application/json; charset=utf-8',
            'Cache-Control': 'no-store',
          })
          ..body = jsonEncode({
            playmeshGameInvitationTokenParameter: requestInvitation.inviteToken,
          });

    final operation = _sendAndDecode(
      request,
      originalInvitation: originalInvitation,
      abort: abort,
    );
    return operation.timeout(
      timeout,
      onTimeout: () {
        if (!abort.isCompleted) abort.complete();
        throw const GameInvitationInspectionException(
          GameInvitationInspectionFailure.timedOut,
        );
      },
    );
  }

  Future<InspectedGameInvitation> _sendAndDecode(
    http.AbortableRequest request, {
    required GameInvitation originalInvitation,
    required Completer<void> abort,
  }) async {
    final response = await _httpClient.send(request);
    if ((response.contentLength ?? 0) >
        maxGameInvitationInspectionResponseBytes) {
      if (!abort.isCompleted) abort.complete();
      throw const GameInvitationInspectionException(
        GameInvitationInspectionFailure.invalidResponse,
      );
    }
    final bodyBytes = <int>[];
    await for (final chunk in response.stream) {
      if (bodyBytes.length + chunk.length >
          maxGameInvitationInspectionResponseBytes) {
        if (!abort.isCompleted) abort.complete();
        throw const GameInvitationInspectionException(
          GameInvitationInspectionFailure.invalidResponse,
        );
      }
      bodyBytes.addAll(chunk);
    }
    if (response.statusCode != 200 || !_isJson(response.headers)) {
      throw const GameInvitationInspectionException(
        GameInvitationInspectionFailure.invalidResponse,
      );
    }

    late final Map<String, Object?> body;
    try {
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is! Map) throw const FormatException();
      body = Map<String, Object?>.from(decoded);
    } on Object {
      throw const GameInvitationInspectionException(
        GameInvitationInspectionFailure.invalidResponse,
      );
    }
    final entry = body['entry'];
    final gameId = body['gameId'];
    final gameName = body['gameName'];
    if (entry is! String ||
        !_isControlledEntryPath(entry) ||
        gameId is! String ||
        !isValidPlaymeshGameId(gameId) ||
        gameName is! String ||
        gameName.trim().isEmpty) {
      throw const GameInvitationInspectionException(
        GameInvitationInspectionFailure.invalidResponse,
      );
    }
    return InspectedGameInvitation(
      invitation: originalInvitation,
      gameId: gameId,
      gameName: gameName.trim(),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _httpClient.close();
  }
}

bool _isJson(Map<String, String> headers) =>
    headers['content-type']?.split(';').first.trim().toLowerCase() ==
    'application/json';

bool _isControlledEntryPath(String value) {
  final normalized = value.trim();
  final uri = Uri.tryParse(normalized);
  return normalized == value &&
      uri != null &&
      uri.scheme.isEmpty &&
      uri.authority.isEmpty &&
      uri.path.startsWith('/') &&
      uri.path.length > 1 &&
      !normalized.contains('?') &&
      !normalized.contains('#');
}
