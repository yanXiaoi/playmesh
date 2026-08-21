import 'package:flutter/foundation.dart';

enum PlaymeshShareSection { lan, internet, room }

enum PlaymeshShareActionMode { share, copy }

@immutable
class PlaymeshShareLink {
  const PlaymeshShareLink({
    required this.id,
    required this.url,
    this.label,
    this.qrPngBytes,
  });

  final String id;
  final Uri url;
  final String? label;
  final Uint8List? qrPngBytes;
}

@immutable
class PlaymeshShareParticipant {
  const PlaymeshShareParticipant({
    required this.id,
    required this.name,
    required this.connected,
  });

  final String id;
  final String name;
  final bool connected;
}

@immutable
class PlaymeshShareServerOption {
  const PlaymeshShareServerOption({
    required this.id,
    required this.name,
    this.latencyMilliseconds,
    this.enabled = true,
  }) : assert(latencyMilliseconds == null || latencyMilliseconds >= 0);

  final String id;
  final String name;
  final int? latencyMilliseconds;
  final bool enabled;
}

@immutable
class PlaymeshShareServerCatalog {
  const PlaymeshShareServerCatalog({
    required this.options,
    this.selectedId,
    this.loading = false,
    this.errorMessage,
    this.searchEnabled = true,
    this.selectionEnabled = true,
    this.refreshEnabled = true,
  });

  final List<PlaymeshShareServerOption> options;
  final String? selectedId;
  final bool loading;
  final String? errorMessage;
  final bool searchEnabled;
  final bool selectionEnabled;
  final bool refreshEnabled;
}

@immutable
class PlaymeshSharePanelModel {
  const PlaymeshSharePanelModel({
    required this.title,
    this.lanLinks = const <PlaymeshShareLink>[],
    this.selectedLanLinkId,
    this.internetLinks = const <PlaymeshShareLink>[],
    this.selectedInternetLinkId,
    this.participants = const <PlaymeshShareParticipant>[],
    this.serverCatalog,
    this.lanLoading = false,
    this.lanError,
    this.internetLoading = false,
    this.internetError,
    this.initialSection = PlaymeshShareSection.lan,
  });

  final String title;
  final List<PlaymeshShareLink> lanLinks;
  final String? selectedLanLinkId;
  final List<PlaymeshShareLink> internetLinks;
  final String? selectedInternetLinkId;
  final List<PlaymeshShareParticipant> participants;
  final PlaymeshShareServerCatalog? serverCatalog;
  final bool lanLoading;
  final String? lanError;
  final bool internetLoading;
  final String? internetError;
  final PlaymeshShareSection initialSection;
}

@immutable
class PlaymeshSharePanelStrings {
  const PlaymeshSharePanelStrings({
    required this.closeTooltip,
    required this.lanTab,
    required this.internetTab,
    required this.roomTab,
    required this.lanHint,
    required this.internetHint,
    required this.roomHint,
    required this.noLanLinks,
    required this.noInternetLinks,
    required this.noPlayers,
    required this.serverSearchHint,
    required this.noServers,
    required this.refreshServersTooltip,
    required this.disconnectServer,
    required this.shareLinkTooltip,
    required this.copyLinkTooltip,
    required this.qrSemantics,
    required this.playerOnline,
    required this.playerOffline,
  });

  final String closeTooltip;
  final String lanTab;
  final String internetTab;
  final String roomTab;
  final String lanHint;
  final String internetHint;
  final String roomHint;
  final String noLanLinks;
  final String noInternetLinks;
  final String noPlayers;
  final String serverSearchHint;
  final String noServers;
  final String refreshServersTooltip;
  final String disconnectServer;
  final String shareLinkTooltip;
  final String copyLinkTooltip;
  final String qrSemantics;
  final String playerOnline;
  final String playerOffline;
}

/// Returns a short, non-secret label for a share link.
///
/// Query parameters and fragments are intentionally omitted. The full URI must
/// only be passed to the QR encoder and the host action callback.
String playmeshCompactShareLink(Uri url) {
  final rawHost = url.host.trim();
  final host = rawHost.contains(':') ? '[$rawHost]' : rawHost;
  if (host.isEmpty) {
    return 'link';
  }
  return url.hasPort ? '$host:${url.port}' : host;
}
