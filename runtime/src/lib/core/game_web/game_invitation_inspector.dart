import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/game_id.dart';
import '../diagnostics/playmesh_error_diagnostic.dart';
import '../relay/relay_tunnel.dart';
import 'game_invitation.dart';
import 'game_web_gateway_contract.dart';

const defaultGameInvitationInspectionTimeout = Duration(seconds: 5);
const maxGameInvitationInspectionResponseBytes = 4 * 1024;

typedef RelayClientSessionFactory =
    Future<RelayClientSession> Function({
      required Uri coreBaseUri,
      required Uri invitationUri,
    });

typedef GameCoreBaseUriProvider = Uri? Function();

Future<RelayClientSession> _startRelayInspectionSession({
  required Uri coreBaseUri,
  required Uri invitationUri,
}) {
  return startRelayClientSession(
    coreBaseUri: coreBaseUri,
    invitationUri: invitationUri,
  );
}

enum GameInvitationInspectionFailure {
  invalidInvitation,
  invalidResponse,
  unavailable,
  timedOut,
  closed,
}

class GameInvitationInspectionException
    implements Exception, PlaymeshDiagnosticError {
  const GameInvitationInspectionException(
    this.failure, {
    this.cause,
    this.causeStackTrace,
    this.context = const {},
  });

  final GameInvitationInspectionFailure failure;

  @override
  final Object? cause;

  @override
  final StackTrace? causeStackTrace;

  @override
  final Map<String, String> context;

  @override
  String get code => switch (failure) {
    GameInvitationInspectionFailure.invalidInvitation =>
      'invitation_inspection_invalid',
    GameInvitationInspectionFailure.invalidResponse =>
      'invitation_inspection_invalid_response',
    GameInvitationInspectionFailure.unavailable =>
      'invitation_inspection_unavailable',
    GameInvitationInspectionFailure.timedOut =>
      'invitation_inspection_timed_out',
    GameInvitationInspectionFailure.closed => 'invitation_inspection_closed',
  };

  @override
  String get message => switch (failure) {
    GameInvitationInspectionFailure.invalidInvitation => '游戏邀请无效',
    GameInvitationInspectionFailure.invalidResponse => '游戏邀请响应无效',
    GameInvitationInspectionFailure.unavailable => '游戏邀请入口不可用',
    GameInvitationInspectionFailure.timedOut => '游戏邀请检查超时',
    GameInvitationInspectionFailure.closed => '游戏邀请检查服务已关闭',
  };

  @override
  String toString() => formatPlaymeshDiagnosticError(this);
}

class InspectedGameInvitation {
  InspectedGameInvitation({
    required this.invitation,
    required this.gameId,
    required this.gameName,
    this.resolvedEntryPath,
    RelayClientSession? relayClientSession,
  }) : _relayClientSessionOwner = _RelayClientSessionOwner(relayClientSession);

  final GameInvitation invitation;
  final String gameId;
  final String gameName;
  final String? resolvedEntryPath;
  final _RelayClientSessionOwner _relayClientSessionOwner;

  RelayClientSession? takeRelayClientSession() =>
      _relayClientSessionOwner.take();

  Future<void> close() async {
    final session = takeRelayClientSession();
    await session?.close();
  }
}

class _RelayClientSessionOwner {
  _RelayClientSessionOwner(this._session);

  RelayClientSession? _session;

  RelayClientSession? take() {
    final session = _session;
    _session = null;
    return session;
  }
}

abstract interface class GameInvitationInspector {
  Future<InspectedGameInvitation> inspect(GameInvitation invitation);

  Future<void> close();
}

class DefaultGameInvitationInspector implements GameInvitationInspector {
  factory DefaultGameInvitationInspector({
    Uri? coreBaseUri,
    GameCoreBaseUriProvider? coreBaseUriProvider,
    http.Client? httpClient,
    RelayClientSessionFactory relayClientSessionFactory =
        _startRelayInspectionSession,
    Duration timeout = defaultGameInvitationInspectionTimeout,
  }) => DefaultGameInvitationInspector._(
    httpClient ?? http.Client(),
    coreBaseUri,
    coreBaseUriProvider,
    relayClientSessionFactory,
    timeout,
  );

  DefaultGameInvitationInspector._(
    this._httpClient,
    this._coreBaseUri,
    this._coreBaseUriProvider,
    this._relayClientSessionFactory,
    this.timeout,
  ) {
    if (timeout.inMicroseconds <= 0) {
      throw ArgumentError.value(timeout, 'timeout', '必须大于零');
    }
  }

  final http.Client _httpClient;
  final Uri? _coreBaseUri;
  final GameCoreBaseUriProvider? _coreBaseUriProvider;
  final RelayClientSessionFactory _relayClientSessionFactory;
  final Duration timeout;
  bool _closed = false;

  @override
  Future<InspectedGameInvitation> inspect(GameInvitation invitation) async {
    if (_closed) {
      throw const GameInvitationInspectionException(
        GameInvitationInspectionFailure.closed,
      );
    }
    RelayClientSession? relaySession;
    try {
      var requestInvitation = invitation;
      if (invitation.usesRelay) {
        final coreBaseUri = _coreBaseUriProvider?.call() ?? _coreBaseUri;
        if (coreBaseUri == null) {
          throw UnsupportedError('当前加入入口没有可用的 Go Core');
        }
        if (coreBaseUri.scheme != 'http' ||
            coreBaseUri.host.isEmpty ||
            (coreBaseUri.hasPort && coreBaseUri.port == 0)) {
          throw StateError('Go Core 地址尚未就绪: $coreBaseUri');
        }
        relaySession = await _relayClientSessionFactory(
          coreBaseUri: coreBaseUri,
          invitationUri: invitation.entryUri,
        );
        requestInvitation = GameInvitation.parse(
          relaySession.webGateway.localEntryUri.toString(),
        );
      }
      final inspected = await _inspectHttp(
        requestInvitation: requestInvitation,
        originalInvitation: invitation,
      );
      inspected._relayClientSessionOwner._session = relaySession;
      relaySession = null;
      return inspected;
    } on GameInvitationInspectionException {
      rethrow;
    } on FormatException catch (error, stackTrace) {
      throw GameInvitationInspectionException(
        GameInvitationInspectionFailure.invalidInvitation,
        cause: error,
        causeStackTrace: stackTrace,
        context: const {'operation': 'inspect_invitation'},
      );
    } on UnsupportedError catch (error, stackTrace) {
      throw GameInvitationInspectionException(
        GameInvitationInspectionFailure.unavailable,
        cause: error,
        causeStackTrace: stackTrace,
        context: const {'operation': 'inspect_invitation'},
      );
    } on Object catch (error, stackTrace) {
      throw GameInvitationInspectionException(
        GameInvitationInspectionFailure.unavailable,
        cause: error,
        causeStackTrace: stackTrace,
        context: const {'operation': 'inspect_invitation'},
      );
    } finally {
      // 失败时立即关闭；成功会话移交给 RemoteGameLaunch 并由实际游戏页接管。
      try {
        await relaySession?.close();
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
        throw GameInvitationInspectionException(
          GameInvitationInspectionFailure.timedOut,
          cause: TimeoutException('游戏邀请检查超过 ${timeout.inMilliseconds}ms'),
          context: const {'operation': 'inspect_http'},
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
      throw GameInvitationInspectionException(
        GameInvitationInspectionFailure.invalidResponse,
        cause: FormatException(
          '游戏邀请响应超过 $maxGameInvitationInspectionResponseBytes bytes',
        ),
        context: const {'operation': 'decode_response'},
      );
    }
    final bodyBytes = <int>[];
    await for (final chunk in response.stream) {
      if (bodyBytes.length + chunk.length >
          maxGameInvitationInspectionResponseBytes) {
        if (!abort.isCompleted) abort.complete();
        throw GameInvitationInspectionException(
          GameInvitationInspectionFailure.invalidResponse,
          cause: FormatException(
            '游戏邀请响应超过 $maxGameInvitationInspectionResponseBytes bytes',
          ),
          context: const {'operation': 'decode_response'},
        );
      }
      bodyBytes.addAll(chunk);
    }
    if (response.statusCode != 200 || !_isJson(response.headers)) {
      throw GameInvitationInspectionException(
        GameInvitationInspectionFailure.invalidResponse,
        cause: FormatException(
          '游戏邀请响应状态或类型无效: status=${response.statusCode} '
          'contentType=${response.headers['content-type'] ?? '<missing>'}',
        ),
        context: const {'operation': 'decode_response'},
      );
    }

    late final Map<String, Object?> body;
    try {
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is! Map) throw const FormatException();
      body = Map<String, Object?>.from(decoded);
    } on Object catch (error, stackTrace) {
      throw GameInvitationInspectionException(
        GameInvitationInspectionFailure.invalidResponse,
        cause: error,
        causeStackTrace: stackTrace,
        context: const {'operation': 'decode_json'},
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
      throw GameInvitationInspectionException(
        GameInvitationInspectionFailure.invalidResponse,
        cause: const FormatException('游戏邀请响应缺少合法的 entry/gameId/gameName'),
        context: const {'operation': 'validate_response'},
      );
    }
    return InspectedGameInvitation(
      invitation: originalInvitation,
      gameId: gameId,
      gameName: gameName.trim(),
      resolvedEntryPath: entry,
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
