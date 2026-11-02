import 'package:flutter/material.dart';

/// A small pixel cat that sits at the foot of the overview. Its mood follows
/// the estimate: content inside the band, asleep when the level is low.
class PixelCat extends StatefulWidget {
  const PixelCat({super.key, required this.style, this.level, this.low = 100});

  final String style;
  final double? level;
  final double low;

  @override
  State<PixelCat> createState() => _PixelCatState();
}

class _PixelCatState extends State<PixelCat>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat(reverse: true);

  static const _shape = <String>[
    '..............',
    '..XX......XX..',
    '.XXXX....XXXX.',
    '.XXXXXXXXXXXX.',
    '.XXXXXXXXXXXX.',
    '.XXEXXXXXXEXX.',
    '.XXXXXXXXXXXX.',
    '.XXXXXNNXXXXX.',
    '.XXXXXXXXXXXX.',
    '..XXXXXXXXXX..',
    '...XXXXXXXX...',
    '....XX..XX....',
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  ({Color body, Color shade, Color eye, Color nose}) get _palette =>
      switch (widget.style) {
        'pink' => (
          body: const Color(0xFFF6BFCE),
          shade: const Color(0xFFDFA1B3),
          eye: const Color(0xFF3F3238),
          nose: const Color(0xFFE58BA4),
        ),
        'flag' => (
          body: const Color(0xFF9FD4EE),
          shade: const Color(0xFFF6BFCE),
          eye: const Color(0xFF3F3238),
          nose: const Color(0xFFE58BA4),
        ),
        _ => (
          body: const Color(0xFF9FD4EE),
          shade: const Color(0xFF7FB8D6),
          eye: const Color(0xFF3F3238),
          nose: const Color(0xFFE58BA4),
        ),
      };

  @override
  Widget build(BuildContext context) {
    final sleeping = widget.level != null && widget.level! < widget.low;
    final palette = _palette;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final bob = sleeping ? 0.0 : (_controller.value - 0.5) * 1.2;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.translate(
              offset: Offset(0, bob),
              child: CustomPaint(
                size: const Size(84, 72),
                painter: _CatPainter(
                  shape: _shape,
                  palette: palette,
                  sleeping: sleeping,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              sleeping ? 'z z z' : '· · ·',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CatPainter extends CustomPainter {
  _CatPainter({
    required this.shape,
    required this.palette,
    required this.sleeping,
  });

  final List<String> shape;
  final ({Color body, Color shade, Color eye, Color nose}) palette;
  final bool sleeping;

  @override
  void paint(Canvas canvas, Size size) {
    final cols = shape.first.length;
    final rows = shape.length;
    final cell = size.width / cols;
    final paint = Paint();

    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final ch = shape[y][x];
        if (ch == '.') continue;
        final rect = Rect.fromLTWH(x * cell, y * cell, cell + 0.4, cell + 0.4);
        switch (ch) {
          case 'X':
            paint.color = (y % 3 == 0 && x > cols ~/ 2)
                ? palette.shade
                : palette.body;
          case 'E':
            if (sleeping) {
              paint.color = palette.shade;
              canvas.drawRect(
                Rect.fromLTWH(
                  x * cell,
                  y * cell + cell * 0.35,
                  cell,
                  cell * 0.3,
                ),
                paint,
              );
              continue;
            }
            paint.color = palette.eye;
          case 'N':
            paint.color = palette.nose;
          default:
            paint.color = palette.body;
        }
        canvas.drawRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CatPainter old) =>
      old.sleeping != sleeping || old.palette != palette || old.shape != shape;
}
