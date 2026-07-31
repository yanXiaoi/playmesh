import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/game_package/game_package_icon.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../models/game_summary.dart';
import '../../models/user_profile.dart';
import '../../ui/playmesh_ui.dart';
import '../game/game_page.dart';
import '../game/join_game_page.dart';
import '../games/game_library_page.dart';
import '../games/online_game_library_page.dart';
import '../profile/profile_page.dart';
import '../settings/settings_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.user,
    this.featuredGame,
    this.games = const [],
    this.onOpenOnline,
    this.gameLibraryLoading = false,
    this.gameLibraryError,
    this.onRetryGameLibrary,
    this.externalUrlLauncher,
  });

  static const profileHeroKey = Key('home-profile-hero');
  static const profileIdentityKey = Key('home-profile-identity');
  static const scanJoinKey = Key('home-scan-join');
  static const githubKey = Key('home-github');
  static const gameLibraryLoadingKey = Key('home-game-library-loading');
  static final githubRepositoryUri = Uri.parse(
    'https://github.com/yanXiaoi/playmesh',
  );

  static Key gameQuickLaunchKey(String gameId) =>
      ValueKey('home-game-quick-launch-$gameId');

  final UserProfile user;

  /// 为尚未迁移到 [games] 的调用方保留。
  final GameSummary? featuredGame;
  final List<GameSummary> games;
  final VoidCallback? onOpenOnline;
  final bool gameLibraryLoading;
  final Object? gameLibraryError;
  final VoidCallback? onRetryGameLibrary;
  final Future<bool> Function(Uri uri)? externalUrlLauncher;

  List<GameSummary> get _visibleGames {
    final featured = featuredGame;
    final candidates = games.isNotEmpty
        ? [...games.where((game) => game.isRunnable)]
        : featured == null
        ? <GameSummary>[]
        : [if (featured.isRunnable) featured];
    final originalOrder = {
      for (var index = 0; index < candidates.length; index++)
        candidates[index].id: index,
    };
    candidates.sort((left, right) {
      final leftOpened = left.lastOpenedAt;
      final rightOpened = right.lastOpenedAt;
      if (leftOpened != null || rightOpened != null) {
        if (leftOpened == null) return 1;
        if (rightOpened == null) return -1;
        final byOpened = rightOpened.compareTo(leftOpened);
        if (byOpened != 0) return byOpened;
      }
      return originalOrder[left.id]!.compareTo(originalOrder[right.id]!);
    });
    return candidates.take(3).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final compactAppBar = MediaQuery.sizeOf(context).width < 360;
    final scannerSupported =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    void openProfile() =>
        Navigator.of(context).pushNamed(ProfilePage.routeName);
    void openLibrary() =>
        Navigator.of(context).pushNamed(GameLibraryPage.routeName);
    void openGame(GameSummary game) => Navigator.of(context).pushNamed(
      GamePage.routeName,
      arguments: GameLaunchArguments(game: game, enterFullscreenOnLaunch: true),
    );
    void scanAndJoin() => Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(
          name: GameInvitationScannerPage.routeName,
        ),
        builder: (_) => GameInvitationScannerPage(
          initialUserId: user.userId,
          initialNickname: user.nickname,
        ),
      ),
    );
    void openOnline() {
      final callback = onOpenOnline;
      if (callback != null) {
        callback();
        return;
      }
      Navigator.of(context).pushNamed(OnlineGameLibraryPage.routeName);
    }

    void openSettings() =>
        Navigator.of(context).pushNamed(SettingsPage.routeName);
    void openGitHub() {
      unawaited(() async {
        final launcher = externalUrlLauncher;
        var opened = false;
        try {
          opened = launcher != null
              ? await launcher(githubRepositoryUri)
              : await launchUrl(
                  githubRepositoryUri,
                  mode: LaunchMode.externalApplication,
                );
        } on Object catch (error) {
          debugPrint('打开 GitHub 开源仓库失败: $error');
        }
        if (!opened && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.tr('home.github_open_failed'))),
          );
        }
      }());
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Image.asset(
                'assets/branding/playmesh-logo.png',
                width: 30,
                height: 30,
                excludeFromSemantics: true,
              ),
            ),
            if (!compactAppBar) ...[
              const SizedBox(width: 9),
              const Text('Playmesh'),
            ],
          ],
        ),
        actions: [
          IconButton(
            key: scanJoinKey,
            tooltip: context.tr('join.scan'),
            onPressed: scannerSupported ? scanAndJoin : null,
            icon: const Icon(Icons.qr_code_scanner_rounded),
          ),
          IconButton(
            key: githubKey,
            tooltip: context.tr('home.github'),
            onPressed: openGitHub,
            icon: const FaIcon(FontAwesomeIcons.github, size: 22),
          ),
          IconButton(
            tooltip: context.tr('common.settings'),
            onPressed: openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          SizedBox(width: compactAppBar ? 0 : 8),
        ],
      ),
      body: PlaymeshBackground(
        child: SafeArea(
          top: false,
          child: ListView(
            children: [
              ResponsivePage(
                maxWidth: 1040,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EntranceAnimation(
                      child: _ProfileHero(user: user, onPressed: openProfile),
                    ),
                    const SizedBox(height: 18),
                    EntranceAnimation(
                      delay: const Duration(milliseconds: 45),
                      child: _RecentGamesSection(
                        games: _visibleGames,
                        onOpenLibrary:
                            gameLibraryLoading || gameLibraryError != null
                            ? null
                            : openLibrary,
                        onLaunch: openGame,
                        loading: gameLibraryLoading,
                        error: gameLibraryError,
                        onRetry: onRetryGameLibrary,
                      ),
                    ),
                    const SizedBox(height: 22),
                    EntranceAnimation(
                      delay: const Duration(milliseconds: 90),
                      child: _PrimaryActions(
                        onJoin: () => Navigator.of(
                          context,
                        ).pushNamed(JoinGamePage.routeName),
                        onOpenOnline: openOnline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileHero extends StatelessWidget {
  const _ProfileHero({required this.user, required this.onPressed});

  final UserProfile user;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 480;
    final titleStyle =
        (compact
                ? Theme.of(context).textTheme.headlineSmall
                : Theme.of(context).textTheme.headlineMedium)
            ?.copyWith(color: Colors.white, fontWeight: FontWeight.w900);
    return Semantics(
      key: HomePage.profileHeroKey,
      container: true,
      label: context.tr('home.profile'),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(colors.primary, const Color(0xff087b84), 0.32)!,
                Color.lerp(colors.secondary, const Color(0xff554fc4), 0.25)!,
              ],
            ),
          ),
          child: Stack(
            children: [
              PositionedDirectional(
                end: -34,
                top: -42,
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withAlpha(16),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(compact ? 22 : 30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.tr('home.hero_title'), style: titleStyle),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: Text(
                        context.tr('home.hero_subtitle'),
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.white.withAlpha(212),
                          height: 1.45,
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: Material(
                        key: HomePage.profileIdentityKey,
                        color: Colors.white.withAlpha(30),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Colors.white.withAlpha(42)),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          autofocus: true,
                          onTap: onPressed,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _UserAvatar(
                                  user: user,
                                  radius: compact ? 22 : 25,
                                  onHero: true,
                                ),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        user.nickname,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(color: Colors.white),
                                      ),
                                      Text(
                                        context.tr('home.profile_hint'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Colors.white.withAlpha(
                                                190,
                                              ),
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  color: Colors.white,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryActions extends StatelessWidget {
  const _PrimaryActions({required this.onJoin, required this.onOpenOnline});

  final VoidCallback onJoin;
  final VoidCallback onOpenOnline;

  @override
  Widget build(BuildContext context) {
    final actions = [
      _PrimaryAction(
        icon: Icons.qr_code_scanner_rounded,
        title: context.tr('home.join'),
        subtitle: context.tr('home.join_hint'),
        onPressed: onJoin,
      ),
      _PrimaryAction(
        icon: Icons.public_outlined,
        title: context.tr('home.online_library'),
        subtitle: context.tr('home.online_hint'),
        onPressed: onOpenOnline,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 720 ? 2 : 1;
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final action in actions)
              SizedBox(
                width: width,
                child: _PrimaryActionTile(action: action),
              ),
          ],
        );
      },
    );
  }
}

class _PrimaryAction {
  const _PrimaryAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;
}

class _PrimaryActionTile extends StatelessWidget {
  const _PrimaryActionTile({required this.action});

  final _PrimaryAction action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: action.onPressed,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
          child: Row(
            children: [
              GradientIcon(icon: action.icon, size: 54, iconSize: 27),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      action.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      action.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentGamesSection extends StatelessWidget {
  const _RecentGamesSection({
    required this.games,
    required this.onOpenLibrary,
    required this.onLaunch,
    required this.loading,
    this.error,
    this.onRetry,
  });

  final List<GameSummary> games;
  final VoidCallback? onOpenLibrary;
  final ValueChanged<GameSummary> onLaunch;
  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: context.tr('home.library_recent'),
          eyebrow: context.tr('home.quick_launch'),
          onTap: onOpenLibrary,
          action: TextButton.icon(
            onPressed: onOpenLibrary,
            icon: const Icon(Icons.arrow_forward_rounded, size: 18),
            label: Text(context.tr('home.view_all')),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: loading
              ? Semantics(
                  key: HomePage.gameLibraryLoadingKey,
                  liveRegion: true,
                  child: ListTile(
                    leading: const SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    title: Text(context.tr('library.title')),
                    subtitle: Text(context.tr('library.loading')),
                  ),
                )
              : error != null
              ? ListTile(
                  leading: Icon(
                    Icons.error_outline_rounded,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(context.tr('common.error')),
                  subtitle: Text(
                    context.tr(
                      'error.library_scan',
                      arguments: {'error': error},
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: onRetry == null
                      ? null
                      : TextButton(
                          onPressed: onRetry,
                          child: Text(context.tr('common.retry')),
                        ),
                )
              : games.isEmpty
              ? ListTile(
                  onTap: onOpenLibrary,
                  leading: const GradientIcon(
                    icon: Icons.sports_esports_outlined,
                    size: 48,
                    iconSize: 24,
                  ),
                  title: Text(context.tr('library.title')),
                  subtitle: Text(context.tr('home.local_empty_hint')),
                  trailing: const Icon(Icons.arrow_forward_rounded),
                )
              : Column(
                  children: [
                    for (var index = 0; index < games.length; index++) ...[
                      _HomeGameRow(
                        game: games[index],
                        onOpen: () => onLaunch(games[index]),
                      ),
                      if (index != games.length - 1)
                        const Divider(height: 1, indent: 76),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _UserAvatar extends StatelessWidget {
  const _UserAvatar({
    required this.user,
    required this.radius,
    this.onHero = false,
  });

  final UserProfile user;
  final double radius;
  final bool onHero;

  @override
  Widget build(BuildContext context) {
    final bytes = user.avatarBytes;
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: onHero
          ? Colors.white
          : Theme.of(context).colorScheme.primaryContainer,
      foregroundColor: onHero
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).colorScheme.onPrimaryContainer,
      child: Icon(Icons.person_rounded, size: radius * 1.15),
    );
    if (bytes == null || bytes.isEmpty) return fallback;
    return ClipOval(
      child: Image.memory(
        bytes,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

class _HomeGameRow extends StatelessWidget {
  const _HomeGameRow({required this.game, required this.onOpen});

  final GameSummary game;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final publisher = game.author.trim().isEmpty
        ? context.tr('library.publisher_unknown')
        : game.author;
    return InkWell(
      key: HomePage.gameQuickLaunchKey(game.id),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _LocalGameIcon(game: game, size: 68),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    game.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${context.tr('common.publisher')}：$publisher',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    gameLibraryMetadata(context, game),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.play_arrow_rounded),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.eyebrow,
    this.onTap,
    this.action,
  });

  final String title;
  final String eyebrow;
  final VoidCallback? onTap;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 28,
                    decoration: BoxDecoration(
                      color: colors.secondary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          eyebrow,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: colors.primary,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                        ),
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (action case final action?) ...[const SizedBox(width: 8), action],
      ],
    );
  }
}

class _LocalGameIcon extends StatelessWidget {
  const _LocalGameIcon({required this.game, required this.size});

  final GameSummary game;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = GradientIcon(
      icon: Icons.sports_esports_outlined,
      size: size,
      iconSize: size * 0.5,
    );
    final path = game.localIconPath;
    if (path == null || path.trim().isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image(
        image: ResizeImage.resizeIfNeeded(
          (size * MediaQuery.devicePixelRatioOf(context)).round(),
          null,
          GamePackageIconImageProvider(File(path)),
        ),
        width: size,
        height: size,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}
