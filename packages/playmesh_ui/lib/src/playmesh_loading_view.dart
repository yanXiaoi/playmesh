import 'package:flutter/material.dart';

/// The shared, intentionally quiet loading surface used while Playmesh boots
/// a game and waits for the App SDK to take ownership of input.
class PlaymeshLoadingView extends StatelessWidget {
  const PlaymeshLoadingView({
    super.key,
    this.backgroundColor = Colors.black,
    this.semanticsLabel = 'Playmesh loading',
  });

  final Color backgroundColor;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final animationsDisabled = MediaQuery.disableAnimationsOf(context);
    return ColoredBox(
      color: backgroundColor,
      child: Semantics(
        label: semanticsLabel,
        liveRegion: true,
        child: ExcludeSemantics(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox.square(
                  dimension: 116,
                  child: RepaintBoundary(
                    child: CustomPaint(painter: _PlaymeshLogoPainter()),
                  ),
                ),
                const SizedBox(height: 28),
                SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(
                    value: animationsDisabled ? 0.72 : null,
                    strokeWidth: 2.4,
                    strokeCap: StrokeCap.round,
                    color: const Color(0xff35d4c5),
                    backgroundColor: const Color(0x337b65ef),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaymeshLogoPainter extends CustomPainter {
  const _PlaymeshLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 116;
    final topLeft = Offset(29 * scale, 25 * scale);
    final right = Offset(89 * scale, 58 * scale);
    final bottomLeft = Offset(29 * scale, 93 * scale);
    final strokeWidth = 13 * scale;
    final bounds = Offset.zero & size;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xff35d4c5), Color(0xff7b65ef)],
        stops: [0.2, 0.72],
      ).createShader(bounds);
    final path = Path()
      ..moveTo(topLeft.dx, topLeft.dy)
      ..lineTo(right.dx, right.dy)
      ..lineTo(bottomLeft.dx, bottomLeft.dy)
      ..close();
    canvas.drawPath(path, edge);

    final node = Paint()
      ..style = PaintingStyle.fill
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xff35d4c5), Color(0xff7b65ef)],
      ).createShader(bounds);
    final cutout = Paint()..color = const Color(0xff000000);
    for (final center in [topLeft, right, bottomLeft]) {
      canvas.drawCircle(center, 14 * scale, node);
      canvas.drawCircle(center, 5.5 * scale, cutout);
    }

    final play = Path()
      ..moveTo(48 * scale, 43 * scale)
      ..lineTo(48 * scale, 74 * scale)
      ..quadraticBezierTo(48 * scale, 80 * scale, 54 * scale, 76.5 * scale)
      ..lineTo(77 * scale, 62 * scale)
      ..quadraticBezierTo(82 * scale, 58 * scale, 77 * scale, 54 * scale)
      ..lineTo(54 * scale, 39.5 * scale)
      ..quadraticBezierTo(48 * scale, 36 * scale, 48 * scale, 43 * scale)
      ..close();
    canvas.drawPath(play, Paint()..color = const Color(0xff35d4c5));
  }

  @override
  bool shouldRepaint(covariant _PlaymeshLogoPainter oldDelegate) => false;
}
