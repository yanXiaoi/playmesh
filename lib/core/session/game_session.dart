import 'dart:convert';

class GameSessionPlayer {
  const GameSessionPlayer({
    required this.id,
    required this.nickname,
    required this.connected,
    required this.role,
  });

  factory GameSessionPlayer.fromJson(Map<String, Object?> json) {
    return GameSessionPlayer(
      id: json['id']! as String,
      nickname: json['nickname']! as String,
      connected: json['connected']! as bool,
      role: json['role']! as String,
    );
  }

  final String id;
  final String nickname;
  final bool connected;
  final String role;

  Map<String, Object?> toJson() => {
    'id': id,
    'nickname': nickname,
    'connected': connected,
    'role': role,
  };
}

class GameSessionSnapshot {
  const GameSessionSnapshot({
    required this.id,
    required this.joinCode,
    required this.gameId,
    required this.displayMode,
    required this.state,
    required this.minPlayers,
    required this.maxPlayers,
    required this.authorityClientId,
    required this.players,
  });

  factory GameSessionSnapshot.fromJson(Map<String, Object?> json) {
    final players = json['players'];
    if (players is! List) {
      throw const FormatException('session.players 必须是数组');
    }
    return GameSessionSnapshot(
      id: json['id']! as String,
      joinCode: json['joinCode']! as String,
      gameId: json['gameId']! as String,
      displayMode: json['displayMode']! as String,
      state: json['state']! as String,
      minPlayers: json['minPlayers']! as int,
      maxPlayers: json['maxPlayers']! as int,
      authorityClientId: json['authorityClientId']! as String,
      players: players
          .map(
            (value) => GameSessionPlayer.fromJson(
              Map<String, Object?>.from(value! as Map),
            ),
          )
          .toList(growable: false),
    );
  }

  final String id;
  final String joinCode;
  final String gameId;
  final String displayMode;
  final String state;
  final int minPlayers;
  final int maxPlayers;
  final String authorityClientId;
  final List<GameSessionPlayer> players;

  Map<String, Object?> toJson() => {
    'id': id,
    'joinCode': joinCode,
    'gameId': gameId,
    'displayMode': displayMode,
    'state': state,
    'minPlayers': minPlayers,
    'maxPlayers': maxPlayers,
    'authorityClientId': authorityClientId,
    'players': players.map((player) => player.toJson()).toList(),
  };
}

class GameSessionCredential {
  const GameSessionCredential({
    required this.player,
    required this.token,
    required this.reconnected,
  });

  final GameSessionPlayer player;
  final String token;
  final bool reconnected;
}

class GameSessionBootstrap {
  const GameSessionBootstrap({
    required this.session,
    required this.credential,
    required this.webSocketPath,
    required this.binaryWebSocketPath,
  });

  factory GameSessionBootstrap.fromJson(Map<String, Object?> json) {
    final credential = Map<String, Object?>.from(json['credential']! as Map);
    return GameSessionBootstrap(
      session: GameSessionSnapshot.fromJson(
        Map<String, Object?>.from(json['session']! as Map),
      ),
      credential: GameSessionCredential(
        player: GameSessionPlayer.fromJson(
          Map<String, Object?>.from(credential['player']! as Map),
        ),
        token: credential['token']! as String,
        reconnected: credential['reconnected'] as bool? ?? false,
      ),
      webSocketPath: json['webSocketPath']! as String,
      binaryWebSocketPath: json['binaryWebSocketPath']! as String,
    );
  }

  final GameSessionSnapshot session;
  final GameSessionCredential credential;
  final String webSocketPath;
  final String binaryWebSocketPath;
}

Map<String, Object?> decodeSessionMessage(Object? value) {
  final decoded = jsonDecode(value! as String);
  if (decoded is! Map) {
    throw const FormatException('会话消息根节点必须是对象');
  }
  return Map<String, Object?>.from(decoded);
}
