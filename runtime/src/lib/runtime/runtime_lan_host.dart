import 'dart:typed_data';

import '../core/diagnostics/playmesh_error_diagnostic.dart';

final class RuntimeLanDiscoveredGame {
  const RuntimeLanDiscoveredGame({
    required this.instanceId,
    required this.gameId,
    required this.name,
    required this.host,
  });

  final String instanceId;
  final String gameId;
  final String name;
  final String host;
}

final class RuntimeLanJoinAction {
  const RuntimeLanJoinAction(this.afterResponse);

  final Future<void> Function() afterResponse;
}

final class RuntimeLanShareLink {
  const RuntimeLanShareLink({
    required this.url,
    required this.type,
    required this.pngBytes,
  });

  final Uri url;
  final String type;
  final Uint8List pngBytes;
}

abstract interface class RuntimeLanHost {
  Future<List<RuntimeLanDiscoveredGame>> discoverGames();

  Future<RuntimeLanJoinAction> prepareDiscoveredJoin(String instanceId);

  Future<RuntimeLanJoinAction> prepareInvitationJoin(String invitationUrl);

  Future<RuntimeLanJoinAction> prepareQrJoin();

  Future<void> setPublished();

  Future<List<RuntimeLanShareLink>> getShareLinks();

  void resetDocument();

  Future<void> close();
}

final class RuntimeLanException implements Exception, PlaymeshDiagnosticError {
  const RuntimeLanException(
    this.code,
    this.message, {
    this.cause,
    this.causeStackTrace,
    this.context = const {},
  });

  @override
  final String code;
  @override
  final String message;

  @override
  final Object? cause;

  @override
  final StackTrace? causeStackTrace;

  @override
  final Map<String, String> context;

  @override
  String toString() => formatPlaymeshDiagnosticError(this);
}
