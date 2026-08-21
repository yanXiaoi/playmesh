import 'dart:convert';
import 'dart:math';

import '../../models/game_id.dart';
import 'lan_game_presence.dart';

const maxLanGameNameUtf8Bytes = 240;
const _soloPayloadKeys = <String>{
  'gameId',
  'name',
  'inviteToken',
  'hostNickname',
  'mode',
};
const _multiplayerPayloadKeys = <String>{
  ..._soloPayloadKeys,
  'playerCount',
  'maxPlayers',
};

class LanGameAdvertisement {
  const LanGameAdvertisement({
    required this.instanceId,
    required this.gameId,
    required this.name,
    required this.inviteToken,
    required this.presence,
  });

  factory LanGameAdvertisement.create({
    required String gameId,
    required String name,
    required String inviteToken,
    required LanGamePresence presence,
  }) => LanGameAdvertisement(
    instanceId: _newLanGameInstanceId(),
    gameId: gameId,
    name: name,
    inviteToken: inviteToken,
    presence: presence,
  ).validated();

  factory LanGameAdvertisement.fromPayload({
    required String instanceId,
    required Map<String, String> payload,
  }) {
    final mode = payload['mode'];
    final expectedKeys = mode == 'solo'
        ? _soloPayloadKeys
        : mode == 'multiplayer'
        ? _multiplayerPayloadKeys
        : const <String>{};
    final actualKeys = payload.keys.toSet();
    if (expectedKeys.isEmpty ||
        actualKeys.difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(actualKeys).isNotEmpty) {
      throw const FormatException('局域网发现 payload 字段无效');
    }
    return LanGameAdvertisement(
      instanceId: instanceId,
      gameId: payload['gameId'] ?? '',
      name: payload['name'] ?? '',
      inviteToken: payload['inviteToken'] ?? '',
      presence: mode == 'solo'
          ? LanGamePresence.solo(hostNickname: payload['hostNickname'] ?? '')
          : LanGamePresence.multiplayer(
              hostNickname: payload['hostNickname'] ?? '',
              playerCount: _parseCanonicalPlayerCount(payload['playerCount']),
              maxPlayers: _parseCanonicalPlayerCount(payload['maxPlayers']),
            ),
    ).validated();
  }

  final String instanceId;
  final String gameId;
  final String name;
  final String inviteToken;
  final LanGamePresence presence;

  LanGameAdvertisement validated() {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(instanceId)) {
      throw const FormatException('局域网发现 instance 无效');
    }
    if (!isValidPlaymeshGameId(gameId)) {
      throw const FormatException('局域网发现 gameId 无效');
    }
    final nameBytes = utf8.encode(name);
    if (name.isEmpty || nameBytes.length > maxLanGameNameUtf8Bytes) {
      throw const FormatException('局域网发现游戏名称无效');
    }
    final tokenBytes = utf8.encode(inviteToken);
    if (inviteToken.isEmpty || tokenBytes.length > 200) {
      throw const FormatException('局域网发现邀请凭据无效');
    }
    presence.validated();
    return this;
  }

  LanGameAdvertisement withPresence(LanGamePresence value) =>
      LanGameAdvertisement(
        instanceId: instanceId,
        gameId: gameId,
        name: name,
        inviteToken: inviteToken,
        presence: value,
      ).validated();

  Map<String, String> toPayload() {
    validated();
    final payload = <String, String>{
      'gameId': gameId,
      'name': name,
      'inviteToken': inviteToken,
      'hostNickname': presence.hostNickname,
      'mode': presence.isSolo ? 'solo' : 'multiplayer',
    };
    if (!presence.isSolo) {
      payload
        ..['playerCount'] = presence.playerCount!.toString()
        ..['maxPlayers'] = presence.maxPlayers!.toString();
    }
    return Map.unmodifiable(payload);
  }
}

int _parseCanonicalPlayerCount(String? value) {
  if (value == null || !RegExp(r'^(?:0|[1-9][0-9]{0,4})$').hasMatch(value)) {
    return -1;
  }
  return int.parse(value);
}

String _newLanGameInstanceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(18, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}
