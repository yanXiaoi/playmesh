import 'package:flutter/material.dart';

abstract final class PlaymeshTheme {
  static const ink = Color(0xff14211d);
  static const mist = Color(0xfff3f7f4);
  static const emerald = Color(0xff087f6d);
  static const violet = Color(0xff6558d9);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: emerald,
      brightness: Brightness.light,
      primary: emerald,
      secondary: violet,
      surface: Colors.white,
    );
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: mist,
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Color(0xeef3f7f4),
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: const Color(0xf7ffffff),
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: Color(0x1f087f6d)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          side: const BorderSide(color: Color(0x33087f6d)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xd9ffffff),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0x24087f6d)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0x24087f6d)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: emerald, width: 1.6),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dialogTheme: DialogThemeData(
        elevation: 16,
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xffeef8f3), Color(0xfff7f5ff), Color(0xfff4f8f6)],
          stops: [0, 0.55, 1],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned(
            top: -110,
            right: -90,
            child: _GlowOrb(size: 280, color: Color(0x1f6558d9)),
          ),
          const Positioned(
            bottom: -130,
            left: -100,
            child: _GlowOrb(size: 310, color: Color(0x23087f6d)),
          ),
          child,
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
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
    final width = MediaQuery.sizeOf(context).width;
    final horizontal = width < 420
        ? 14.0
        : width < 760
        ? 20.0
        : 32.0;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(horizontal, top, horizontal, bottom),
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
    this.offset = const Offset(0, 0.045),
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

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _opacity = Tween<double>(begin: 0.88, end: 1).animate(curve);
    _slide = Tween<Offset>(
      begin: widget.offset * 0.35,
      end: Offset.zero,
    ).animate(curve);
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
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
    final forwardCurve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    final reverseCurve = CurvedAnimation(
      parent: animation,
      curve: Curves.linear,
      reverseCurve: Curves.easeInOutCubic,
    );
    return _PlaymeshDirectionalPageTransition(
      animation: animation,
      forwardOpacity: Tween<double>(begin: 0.94, end: 1).animate(forwardCurve),
      forwardPosition: Tween<Offset>(
        begin: const Offset(0.018, 0),
        end: Offset.zero,
      ).animate(forwardCurve),
      reversePosition: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(reverseCurve),
      child: child,
    );
  }
}

class _PlaymeshDirectionalPageTransition extends AnimatedWidget {
  const _PlaymeshDirectionalPageTransition({
    required this.animation,
    required this.forwardOpacity,
    required this.forwardPosition,
    required this.reversePosition,
    required this.child,
  }) : super(listenable: animation);

  final Animation<double> animation;
  final Animation<double> forwardOpacity;
  final Animation<Offset> forwardPosition;
  final Animation<Offset> reversePosition;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final page = RepaintBoundary(child: child);
    if (animation.status == AnimationStatus.reverse) {
      return FractionalTranslation(
        translation: reversePosition.value,
        child: page,
      );
    }
    return Opacity(
      opacity: forwardOpacity.value,
      child: FractionalTranslation(
        translation: forwardPosition.value,
        child: page,
      ),
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
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [PlaymeshTheme.emerald, PlaymeshTheme.violet],
        ),
        borderRadius: BorderRadius.circular(size * 0.34),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2b087f6d),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: iconSize),
    );
  }
}
