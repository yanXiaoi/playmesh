import 'package:playmesh_share_ui/playmesh_share_ui.dart';

import 'runtime_lan_host.dart';
import 'runtime_session.dart';

final class RuntimeSharePanelPresentation {
  const RuntimeSharePanelPresentation({
    required this.model,
    required this._linksById,
  });

  final PlaymeshSharePanelModel model;
  final Map<String, Uri> _linksById;

  Uri? linkForId(String id) => _linksById[id];
}

RuntimeSharePanelPresentation buildRuntimeSharePanelPresentation({
  required String title,
  required Iterable<RuntimeLanShareLink> links,
  RuntimeSessionConnection? session,
  String? bundledRelayName,
  int? bundledRelayLatencyMilliseconds,
}) {
  final lanLinks = <PlaymeshShareLink>[];
  final internetLinks = <PlaymeshShareLink>[];
  final linksById = <String, Uri>{};
  var lanIndex = 0;
  var internetIndex = 0;
  for (final link in links) {
    final isInternet = link.type == 'wan';
    final id = isInternet ? 'internet-${internetIndex++}' : 'lan-${lanIndex++}';
    linksById[id] = link.url;
    final presentationLink = PlaymeshShareLink(
      id: id,
      url: link.url,
      qrPngBytes: link.pngBytes,
    );
    if (isInternet) {
      internetLinks.add(presentationLink);
    } else {
      lanLinks.add(presentationLink);
    }
  }
  return RuntimeSharePanelPresentation(
    model: PlaymeshSharePanelModel(
      title: title,
      lanLinks: lanLinks,
      selectedLanLinkId: lanLinks.isEmpty ? null : lanLinks.first.id,
      internetLinks: internetLinks,
      selectedInternetLinkId: internetLinks.isEmpty
          ? null
          : internetLinks.first.id,
      participants: _participants(session?.snapshot),
      initialSection: lanLinks.isEmpty && internetLinks.isNotEmpty
          ? PlaymeshShareSection.internet
          : PlaymeshShareSection.lan,
      serverCatalog:
          internetLinks.isNotEmpty &&
              bundledRelayName != null &&
              bundledRelayLatencyMilliseconds != null
          ? PlaymeshShareServerCatalog(
              options: [
                PlaymeshShareServerOption(
                  id: 'bundled-relay',
                  name: bundledRelayName,
                  latencyMilliseconds: bundledRelayLatencyMilliseconds,
                ),
              ],
              selectedId: 'bundled-relay',
              searchEnabled: false,
              selectionEnabled: false,
              refreshEnabled: false,
            )
          : null,
    ),
    linksById: Map.unmodifiable(linksById),
  );
}

List<PlaymeshShareParticipant> _participants(Map<String, Object?>? snapshot) {
  final rawPlayers = snapshot?['players'];
  if (rawPlayers is! List) return const <PlaymeshShareParticipant>[];
  final participants = <PlaymeshShareParticipant>[];
  for (final rawPlayer in rawPlayers) {
    if (rawPlayer is! Map) continue;
    final player = Map<String, Object?>.from(rawPlayer);
    final id = player['id'];
    final nickname = player['nickname'];
    if (id is! String || id.isEmpty || nickname is! String) continue;
    final normalizedNickname = nickname.trim();
    if (normalizedNickname.isEmpty) continue;
    participants.add(
      PlaymeshShareParticipant(
        id: id,
        name: normalizedNickname,
        connected: player['connected'] != false,
      ),
    );
  }
  return List.unmodifiable(participants);
}

PlaymeshSharePanelStrings runtimeSharePanelStrings({
  required bool useChinese,
}) => useChinese ? _zhCnSharePanelStrings : _enUsSharePanelStrings;

String runtimeSharePanelTitle({required bool useChinese}) =>
    useChinese ? '分享当前游戏' : 'Share current game';

String runtimeShareLinkCopiedMessage({required bool useChinese}) =>
    useChinese ? '链接已复制' : 'Link copied';

String runtimeBundledRelayFallbackName({required bool useChinese}) =>
    useChinese ? '内置中转服务器' : 'Bundled relay server';

const _zhCnSharePanelStrings = PlaymeshSharePanelStrings(
  closeTooltip: '关闭',
  lanTab: '局域网',
  internetTab: '互联网',
  roomTab: '房间',
  lanHint: '同一局域网内的玩家可扫码或使用分享链接加入',
  internetHint: '不在同一局域网的玩家可通过互联网链接加入',
  roomHint: '当前已进入房间的玩家',
  noLanLinks: '当前没有可用的局域网分享链接',
  noInternetLinks: '当前没有可用的互联网分享链接',
  noPlayers: '暂无玩家',
  serverSearchHint: '搜索服务器',
  noServers: '暂无可用服务器',
  refreshServersTooltip: '刷新服务器',
  disconnectServer: '断开服务器',
  shareLinkTooltip: '分享链接',
  copyLinkTooltip: '复制链接',
  qrSemantics: '加入游戏的二维码',
  playerOnline: '在线',
  playerOffline: '离线',
);

const _enUsSharePanelStrings = PlaymeshSharePanelStrings(
  closeTooltip: 'Close',
  lanTab: 'Local network',
  internetTab: 'Internet',
  roomTab: 'Room',
  lanHint: 'Players on the same local network can scan or use this link',
  internetHint: 'Players outside your local network can use this Internet link',
  roomHint: 'Players currently in this room',
  noLanLinks: 'No local-network link is available',
  noInternetLinks: 'No Internet link is available',
  noPlayers: 'No players yet',
  serverSearchHint: 'Search servers',
  noServers: 'No servers are available',
  refreshServersTooltip: 'Refresh servers',
  disconnectServer: 'Disconnect server',
  shareLinkTooltip: 'Share link',
  copyLinkTooltip: 'Copy link',
  qrSemantics: 'QR code for joining the game',
  playerOnline: 'Online',
  playerOffline: 'Offline',
);
