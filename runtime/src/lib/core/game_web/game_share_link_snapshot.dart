import 'dart:collection';

enum GameShareLinkType { lan, wan }

class GameShareLink {
  GameShareLink({
    required this.url,
    required this.type,
    required List<int> pngBytes,
  }) : pngBytes = UnmodifiableListView<int>(List<int>.of(pngBytes));

  final Uri url;
  final GameShareLinkType type;
  final List<int> pngBytes;
}

class GameShareLinkSnapshot {
  GameShareLinkSnapshot({
    required this.generation,
    required List<GameShareLink> links,
  }) : links = UnmodifiableListView<GameShareLink>(
         List<GameShareLink>.of(links),
       );

  factory GameShareLinkSnapshot.empty(int generation) =>
      GameShareLinkSnapshot(generation: generation, links: const []);

  final int generation;
  final List<GameShareLink> links;

  List<GameShareLink> get lanLinks => UnmodifiableListView(
    links.where((link) => link.type == GameShareLinkType.lan),
  );

  GameShareLink? get wanLink =>
      links.where((link) => link.type == GameShareLinkType.wan).firstOrNull;
}

class GameShareException implements Exception {
  const GameShareException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}
