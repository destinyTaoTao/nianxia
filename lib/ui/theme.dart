import 'package:flutter/material.dart';

ThemeData notebookTheme(Brightness brightness, {String? fontFamily}) {
  final dark = brightness == Brightness.dark;
  final canvas = Color(dark ? 0xff1c1c1c : 0xfff6f6f6);
  final panel = Color(dark ? 0xff272727 : 0xffffffff);
  final soft = Color(dark ? 0xff333333 : 0xfff1f1f1);
  final ink = Color(dark ? 0xfff4f4f4 : 0xff181818);
  final muted = Color(dark ? 0xffb3b3b3 : 0xff606060);
  final line = Color(dark ? 0xff414141 : 0xffdddddd);
  final inverse = Color(dark ? 0xff181818 : 0xffffffff);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: ink,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      ).copyWith(
        primary: ink,
        onPrimary: inverse,
        secondary: muted,
        onSecondary: inverse,
        surface: panel,
        surfaceContainerLow: panel,
        surfaceContainer: soft,
        surfaceContainerHighest: soft,
        onSurface: ink,
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
  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(14),
  );
  OutlineInputBorder inputBorder(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: width),
      );
  return base.copyWith(
    scaffoldBackgroundColor: canvas,
    iconTheme: IconThemeData(color: ink, size: 22),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: ink,
      inactiveTrackColor: muted.withValues(alpha: .72),
      thumbColor: ink,
      overlayColor: ink.withValues(alpha: .08),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: ink,
      linearTrackColor: line,
      circularTrackColor: line,
    ),
    textTheme: base.textTheme
        .copyWith(
          headlineMedium: TextStyle(
            fontFamily: fontFamily,
            fontSize: 26,
            fontWeight: FontWeight.w600,
            height: 1.3,
            letterSpacing: -.3,
            color: ink,
          ),
          titleLarge: TextStyle(
            fontFamily: fontFamily,
            fontSize: 22,
            fontWeight: FontWeight.w600,
            height: 1.35,
            color: ink,
          ),
          titleMedium: TextStyle(
            fontFamily: fontFamily,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1.5,
            color: ink,
          ),
          bodyLarge: TextStyle(
            fontFamily: fontFamily,
            fontSize: 16,
            height: 1.65,
            color: ink,
          ),
          bodyMedium: TextStyle(
            fontFamily: fontFamily,
            fontSize: 15,
            height: 1.55,
            color: ink,
          ),
          bodySmall: TextStyle(
            fontFamily: fontFamily,
            fontSize: 13,
            height: 1.5,
            color: muted,
          ),
          labelLarge: TextStyle(
            fontFamily: fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
        )
        .apply(fontFamily: fontFamily),
    appBarTheme: AppBarTheme(
      backgroundColor: canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 64,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
    ),
    dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
    cardTheme: CardThemeData(
      color: panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 52),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        elevation: 0,
        shape: controlShape,
        textStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 52),
        backgroundColor: panel,
        side: BorderSide(color: line),
        shape: controlShape,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: controlShape,
        textStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: panel,
      selectedColor: soft,
      checkmarkColor: ink,
      side: BorderSide(color: line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      labelStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: ink,
      ),
      secondaryLabelStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: panel,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      hintStyle: TextStyle(fontFamily: fontFamily, color: muted, fontSize: 15),
      labelStyle: TextStyle(fontFamily: fontFamily, color: muted, fontSize: 14),
      border: inputBorder(line),
      enabledBorder: inputBorder(line),
      focusedBorder: inputBorder(ink, 1.5),
      errorBorder: inputBorder(scheme.error),
      focusedErrorBorder: inputBorder(scheme.error, 1.5),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ink,
      contentTextStyle: TextStyle(
        fontFamily: fontFamily,
        color: inverse,
        fontSize: 14,
        height: 1.5,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: panel,
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
