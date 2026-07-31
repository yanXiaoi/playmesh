import 'dart:async';

import 'package:flutter/material.dart';

abstract final class PlaymeshTheme {
  static const ink = Color(0xff17211d);
  static const mist = Color(0xfff4f7f6);
  static const emerald = Color(0xff087f6d);
  static const violet = Color(0xff2f6fed);
  static const cartridgeAmber = Color(0xffd77d2d);
  static const moss = Color(0xff506649);

  static ThemeData light() {
    return _theme(
      brightness: Brightness.light,
      background: mist,
      surface: Colors.white,
      surfaceRaised: Colors.white,
      foreground: ink,
      primary: emerald,
      onPrimary: Colors.white,
      primaryContainer: const Color(0xffd5eee8),
      onPrimaryContainer: const Color(0xff063e35),
      secondary: violet,
      secondaryContainer: const Color(0xffdbe6ff),
      onSecondaryContainer: const Color(0xff17396f),
      outline: const Color(0xffadb9b3),
      outlineVariant: const Color(0xffd6dfda),
      error: const Color(0xffc24141),
    );
  }

  static ThemeData dark() {
    return _theme(
      brightness: Brightness.dark,
      background: const Color(0xff101614),
      surface: const Color(0xff18201d),
      surfaceRaised: const Color(0xff1d2824),
      foreground: const Color(0xffeaf1ed),
      primary: const Color(0xff4cc7ae),
      onPrimary: const Color(0xff00382f),
      primaryContainer: const Color(0xff164b40),
      onPrimaryContainer: const Color(0xffc9f3e8),
      secondary: const Color(0xff78a6ff),
      secondaryContainer: const Color(0xff263f70),
      onSecondaryContainer: const Color(0xffdae5ff),
      outline: const Color(0xff71807a),
      outlineVariant: const Color(0xff34433f),
      error: const Color(0xffff8d86),
    );
  }

  static ThemeData _theme({
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color surfaceRaised,
    required Color foreground,
    required Color primary,
    required Color onPrimary,
    required Color primaryContainer,
    required Color onPrimaryContainer,
    required Color secondary,
    required Color secondaryContainer,
    required Color onSecondaryContainer,
    required Color outline,
    required Color outlineVariant,
    required Color error,
  }) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: secondary,
      onSecondary: brightness == Brightness.light
          ? Colors.white
          : const Color(0xff082552),
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: onSecondaryContainer,
      tertiary: brightness == Brightness.light ? moss : const Color(0xffb4d1a6),
      onTertiary: brightness == Brightness.light
          ? Colors.white
          : const Color(0xff203719),
      tertiaryContainer: brightness == Brightness.light
          ? const Color(0xffd9e8d1)
          : const Color(0xff354d2f),
      onTertiaryContainer: brightness == Brightness.light
          ? const Color(0xff21371d)
          : const Color(0xffd1ebc7),
      error: error,
      onError: brightness == Brightness.light
          ? Colors.white
          : const Color(0xff690005),
      errorContainer: brightness == Brightness.light
          ? const Color(0xffffdad6)
          : const Color(0xff7c2926),
      onErrorContainer: brightness == Brightness.light
          ? const Color(0xff410002)
          : const Color(0xffffdad6),
      surface: surface,
      onSurface: foreground,
      onSurfaceVariant: brightness == Brightness.light
          ? const Color(0xff48534f)
          : const Color(0xffbdc8c2),
      outline: outline,
      outlineVariant: outlineVariant,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: brightness == Brightness.light
          ? const Color(0xff26312e)
          : const Color(0xffeaf1ed),
      onInverseSurface: brightness == Brightness.light
          ? const Color(0xffedf2ed)
          : const Color(0xff26312e),
      inversePrimary: brightness == Brightness.light
          ? const Color(0xff4cc7ae)
          : emerald,
      surfaceTint: Colors.transparent,
    );
    final base = ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      fontFamily: 'Noto Sans SC',
      fontFamilyFallback: const ['Segoe UI Variable', 'Segoe UI', 'sans-serif'],
    );
    final focusBorder = BorderSide(color: primary, width: 3);
    return base.copyWith(
      scaffoldBackgroundColor: background,
      canvasColor: surface,
      focusColor: primary.withAlpha(92),
      hoverColor: primary.withAlpha(41),
      highlightColor: primary.withAlpha(56),
      textTheme: base.textTheme
          .apply(bodyColor: foreground, displayColor: foreground)
          .copyWith(
            headlineMedium: base.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            titleMedium: base.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            labelLarge: base.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 1,
        shadowColor: Colors.black.withAlpha(46),
        backgroundColor: background,
        foregroundColor: foreground,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: foreground,
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: surfaceRaised,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(color: outlineVariant, thickness: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontWeight: FontWeight.w700),
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? BorderSide(color: onPrimary, width: 3)
                : BorderSide.none,
          ),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return onPrimary.withAlpha(54);
            }
            if (states.contains(WidgetState.focused)) {
              return onPrimary.withAlpha(82);
            }
            if (states.contains(WidgetState.hovered)) {
              return onPrimary.withAlpha(38);
            }
            return null;
          }),
          elevation: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused) ? 6 : 0,
          ),
          shadowColor: WidgetStatePropertyAll(primary.withAlpha(110)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 17, vertical: 11),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? focusBorder
                : BorderSide(color: outline),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) return primaryContainer;
            if (states.contains(WidgetState.hovered)) {
              return primary.withAlpha(28);
            }
            return null;
          }),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          side: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.focused) ? focusBorder : null,
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) return primaryContainer;
            if (states.contains(WidgetState.hovered)) {
              return primary.withAlpha(28);
            }
            return null;
          }),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          side: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.focused) ? focusBorder : null,
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) return primaryContainer;
            if (states.contains(WidgetState.hovered)) {
              return primary.withAlpha(28);
            }
            return null;
          }),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceRaised,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: focusBorder,
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: error),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        minTileHeight: 52,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: brightness == Brightness.light
            ? ink
            : const Color(0xffe4ebe5),
        contentTextStyle: TextStyle(
          color: brightness == Brightness.light
              ? Colors.white
              : const Color(0xff17221f),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      dialogTheme: DialogThemeData(
        elevation: 12,
        backgroundColor: surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _PlaymeshPageTransitionsBuilder(),
          TargetPlatform.iOS: _PlaymeshPageTransitionsBuilder(),
          TargetPlatform.macOS: _PlaymeshPageTransitionsBuilder(),
          TargetPlatform.windows: _PlaymeshPageTransitionsBuilder(),
          TargetPlatform.linux: _PlaymeshPageTransitionsBuilder(),
        },
      ),
    );
  }
}

class PlaymeshBackground extends StatelessWidget {
  const PlaymeshBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: CustomPaint(
        painter: _PlaymeshBackgroundPainter(
          primary: colors.primary,
          secondary: colors.secondary,
          surface: colors.surface,
          brightness: Theme.of(context).brightness,
        ),
        child: child,
      ),
    );
  }
}

class _PlaymeshBackgroundPainter extends CustomPainter {
  const _PlaymeshBackgroundPainter({
    required this.primary,
    required this.secondary,
    required this.surface,
    required this.brightness,
  });

  final Color primary;
  final Color secondary;
  final Color surface;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final isDark = brightness == Brightness.dark;
    final primaryPaint = Paint()..color = primary.withAlpha(isDark ? 22 : 21);
    final secondaryPaint = Paint()
      ..color = secondary.withAlpha(isDark ? 18 : 17);
    final surfacePaint = Paint()..color = surface.withAlpha(isDark ? 80 : 132);

    final topMesh = Path()
      ..moveTo(size.width * 0.46, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height * 0.26)
      ..lineTo(size.width * 0.72, size.height * 0.34)
      ..close();
    canvas.drawPath(topMesh, secondaryPaint);

    final lowerMesh = Path()
      ..moveTo(0, size.height * 0.70)
      ..lineTo(size.width * 0.34, size.height * 0.61)
      ..lineTo(size.width * 0.58, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(lowerMesh, primaryPaint);

    canvas.drawCircle(
      Offset(size.width * 0.08, size.height * 0.19),
      size.shortestSide * 0.22,
      primaryPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.91, size.height * 0.68),
      size.shortestSide * 0.18,
      secondaryPaint,
    );

    final veil = Path()
      ..moveTo(size.width * 0.64, size.height * 0.40)
      ..lineTo(size.width, size.height * 0.34)
      ..lineTo(size.width, size.height * 0.52)
      ..close();
    canvas.drawPath(veil, surfacePaint);
  }

  @override
  bool shouldRepaint(covariant _PlaymeshBackgroundPainter oldDelegate) {
    return primary != oldDelegate.primary ||
        secondary != oldDelegate.secondary ||
        surface != oldDelegate.surface ||
        brightness != oldDelegate.brightness;
  }
}

class ResponsivePage extends StatelessWidget {
  const ResponsivePage({
    super.key,
    required this.child,
    this.maxWidth = 1120,
    this.top = 16,
    this.bottom = 32,
  });

  final Widget child;
  final double maxWidth;
  final double top;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final horizontal = size.width < 420
        ? 14.0
        : size.width < 760
        ? 20.0
        : 32.0;
    final tvSafeInset = size.width >= 1200 ? 28.0 : 0.0;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            horizontal + tvSafeInset,
            top,
            horizontal + tvSafeInset,
            bottom,
          ),
          child: child,
        ),
      ),
    );
  }
}

class EntranceAnimation extends StatefulWidget {
  const EntranceAnimation({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, 0.028),
  });

  final Widget child;
  final Duration delay;
  final Offset offset;

  @override
  State<EntranceAnimation> createState() => _EntranceAnimationState();
}

class _EntranceAnimationState extends State<EntranceAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _opacity = Tween<double>(begin: 0.92, end: 1).animate(curve);
    _slide = Tween<Offset>(
      begin: widget.offset,
      end: Offset.zero,
    ).animate(curve);
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        _delayTimer = null;
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

class _PlaymeshPageTransitionsBuilder extends PageTransitionsBuilder {
  const _PlaymeshPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.isFirst || MediaQuery.disableAnimationsOf(context)) return child;
    final curve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final enterOpacity = Tween<double>(begin: 0.96, end: 1).animate(curve);
    final enterPosition = Tween<Offset>(
      begin: const Offset(0.012, 0),
      end: Offset.zero,
    ).animate(curve);
    // 返回时将退出路由完全移出屏幕。此前 1.2% 的位移使其在几乎整个动画期间
    // 都遮挡着上一条路由，看起来像画面冻结后突然切换。
    // 仅由合成器完成的滑动也避免了全屏透明度混合。
    final exitPosition = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(curve);
    return AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: child),
      builder: (context, child) {
        if (animation.status == AnimationStatus.reverse) {
          return SlideTransition(position: exitPosition, child: child);
        }
        return FadeTransition(
          opacity: enterOpacity,
          child: SlideTransition(position: enterPosition, child: child),
        );
      },
    );
  }
}

class GradientIcon extends StatelessWidget {
  const GradientIcon({
    super.key,
    required this.icon,
    this.size = 48,
    this.iconSize = 24,
  });

  final IconData icon;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            PositionedDirectional(
              start: 0,
              top: 8,
              bottom: 8,
              width: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.secondary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Center(
              child: Icon(
                icon,
                color: colors.onPrimaryContainer,
                size: iconSize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
