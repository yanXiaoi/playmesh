import 'package:flutter/material.dart';

import '../../models/game_summary.dart';
import '../../models/user_profile.dart';
import '../../ui/playmesh_ui.dart';
import '../game/join_game_page.dart';
import '../games/game_library_page.dart';
import '../profile/profile_page.dart';
import '../settings/settings_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.user, required this.featuredGame});

  final UserProfile user;
  final GameSummary? featuredGame;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Image.asset(
                'assets/branding/playmesh-logo.png',
                width: 32,
                height: 32,
              ),
            ),
            const SizedBox(width: 10),
            const Text('Playmesh'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: () =>
                Navigator.of(context).pushNamed(SettingsPage.routeName),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: PlaymeshBackground(
        child: SafeArea(
          child: ListView(
            children: [
              ResponsivePage(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EntranceAnimation(child: _HeroPanel(user: user)),
                    const SizedBox(height: 18),
                    EntranceAnimation(
                      delay: const Duration(milliseconds: 70),
                      child: const _HomeActionGrid(),
                    ),
                    const SizedBox(height: 18),
                    EntranceAnimation(
                      delay: const Duration(milliseconds: 140),
                      child: featuredGame == null
                          ? const _EmptyGameLibrary()
                          : _FeaturedGameCard(game: featuredGame!),
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

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({required this.user});

  final UserProfile user;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff087f6d), Color(0xff405aa9), Color(0xff6558d9)],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x35087f6d),
            blurRadius: 30,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 540;
          final copy = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '让每块屏幕一起玩',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '局域网优先的 HTML 游戏平台，快速创建、分享与加入游戏。',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.white.withValues(alpha: 0.82),
                  height: 1.45,
                ),
              ),
            ],
          );
          final profile = Material(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () =>
                  Navigator.of(context).pushNamed(ProfilePage.routeName),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white,
                      foregroundColor: PlaymeshTheme.emerald,
                      child: Text(
                        user.avatarLabel,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      user.nickname,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.chevron_right,
                      color: Colors.white70,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [copy, const SizedBox(height: 20), profile],
            );
          }
          return Row(
            children: [
              Expanded(child: copy),
              const SizedBox(width: 28),
              profile,
            ],
          );
        },
      ),
    );
  }
}

class _HomeActionGrid extends StatelessWidget {
  const _HomeActionGrid();

  @override
  Widget build(BuildContext context) {
    final actions = [
      _HomeAction(
        icon: Icons.person_outline,
        title: '用户资料',
        subtitle: '昵称与本机身份',
        onTap: () => Navigator.of(context).pushNamed(ProfilePage.routeName),
      ),
      _HomeAction(
        icon: Icons.qr_code_scanner_rounded,
        title: '加入对局',
        subtitle: '扫描主机二维码，无需预先安装游戏',
        onTap: () => Navigator.of(context).pushNamed(JoinGamePage.routeName),
      ),
      _HomeAction(
        icon: Icons.tune_outlined,
        title: '设置',
        subtitle: '连接与开发者工具',
        onTap: () => Navigator.of(context).pushNamed(SettingsPage.routeName),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 850
            ? 3
            : constraints.maxWidth >= 500
            ? 2
            : 1;
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final action in actions)
              SizedBox(
                width: width,
                child: _HomeActionTile(action: action),
              ),
          ],
        );
      },
    );
  }
}

class _HomeAction {
  const _HomeAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
}

class _HomeActionTile extends StatelessWidget {
  const _HomeActionTile({required this.action});

  final _HomeAction action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: action.onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              GradientIcon(icon: action.icon),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      action.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      action.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios_rounded, size: 15),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyGameLibrary extends StatelessWidget {
  const _EmptyGameLibrary();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => Navigator.of(context).pushNamed(GameLibraryPage.routeName),
        child: const Padding(
          padding: EdgeInsets.all(22),
          child: Row(
            children: [
              GradientIcon(icon: Icons.videogame_asset_off_outlined),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('游戏库', style: TextStyle(fontWeight: FontWeight.w700)),
                    SizedBox(height: 4),
                    Text('当前为空，打开后可导入 Playmesh 游戏包'),
                  ],
                ),
              ),
              Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeaturedGameCard extends StatelessWidget {
  const _FeaturedGameCard({required this.game});

  final GameSummary game;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => Navigator.of(context).pushNamed(GameLibraryPage.routeName),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const GradientIcon(
                icon: Icons.sports_esports_rounded,
                size: 58,
                iconSize: 29,
              ),
              const SizedBox(width: 17),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '游戏库',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: PlaymeshTheme.emerald,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      game.name,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      game.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.arrow_forward_rounded),
            ],
          ),
        ),
      ),
    );
  }
}
