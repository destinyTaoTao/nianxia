import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/ui/common.dart';
import 'package:nianxia/ui/theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name} 截止提示只在临近且仍录音时播报，窄屏大字不溢出', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Future<void> show(int elapsed, bool recording) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: notebookTheme(brightness, reduceMotion: true),
              home: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: Scaffold(
                  body: Center(
                    child: CaptureLimitHint(
                      elapsedMs: elapsed,
                      recording: recording,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
        }

        const text = '即将达到两分钟，录音将自动结束。';
        await show(104999, true);
        expect(find.text(text), findsNothing);
        await show(105000, true);
        expect(find.text(text), findsOneWidget);
        expect(
          tester.getSemantics(find.text(text)),
          matchesSemantics(
            label: text,
            isLiveRegion: true,
            textDirection: TextDirection.ltr,
          ),
        );
        expect(tester.takeException(), isNull);
        await show(120000, false);
        expect(find.text(text), findsNothing);
      } finally {
        semantics.dispose();
      }
    });
  }
}
