import 'package:flutter/material.dart';

ThemeData notebookTheme(Brightness brightness, {String? fontFamily}) {
  final dark = brightness == Brightness.dark;
  final bg = Color(dark ? 0xff212121 : 0xffffffff),
      surface = Color(dark ? 0xff303030 : 0xfff7f7f8);
  final ink = Color(dark ? 0xfff5f5f5 : 0xff171717),
      muted = Color(dark ? 0xffb4b4b4 : 0xff666666);
  final line = Color(dark ? 0xff4a4a4a : 0xffe5e5e5),
      inverse = Color(dark ? 0xff171717 : 0xffffffff);
  final scheme = ColorScheme.fromSeed(seedColor: ink, brightness: brightness)
      .copyWith(
        primary: ink,
        onPrimary: inverse,
        secondary: muted,
        onSecondary: inverse,
        surface: bg,
        onSurface: ink,
        surfaceContainerHighest: surface,
        onSurfaceVariant: muted,
        outline: muted,
        outlineVariant: line,
        surfaceTint: Colors.transparent,
      );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: fontFamily,
  );
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: ink,
      linearTrackColor: line,
      circularTrackColor: line,
    ),
    textTheme: base.textTheme
        .copyWith(
          headlineMedium: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            height: 1.25,
            color: ink,
          ),
          titleLarge: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
          titleMedium: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            height: 1.5,
            color: ink,
          ),
          bodyLarge: TextStyle(fontSize: 17, height: 1.7, color: ink),
          bodyMedium: TextStyle(fontSize: 16, height: 1.5, color: ink),
          bodySmall: TextStyle(fontSize: 14, height: 1.5, color: muted),
        )
        .apply(fontFamily: fontFamily),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
    ),
    dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 52),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 52),
        side: BorderSide(color: line),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.all(16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: bg,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
  );
}

class NoteMark extends StatelessWidget {
  const NoteMark({super.key, this.size = 40});
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '念下，语音灵感本',
    image: true,
    child: CustomPaint(
      size: Size.square(size),
      painter: _MarkPainter(Theme.of(context).colorScheme.onSurface),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 48;
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(12, 7)
        ..lineTo(31, 7)
        ..lineTo(39, 15)
        ..lineTo(39, 37)
        ..quadraticBezierTo(39, 41, 35, 41)
        ..lineTo(12, 41)
        ..quadraticBezierTo(8, 41, 8, 37)
        ..lineTo(8, 11)
        ..quadraticBezierTo(8, 7, 12, 7),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(30, 8)
        ..lineTo(30, 16)
        ..lineTo(38, 16),
      paint,
    );
    for (final v in [
      (17.0, 24.0, 30.0),
      (24.0, 20.0, 34.0),
      (31.0, 24.0, 30.0),
    ]) {
      canvas.drawLine(Offset(v.$1, v.$2), Offset(v.$1, v.$3), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => old.color != color;
}
