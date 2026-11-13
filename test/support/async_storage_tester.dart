import 'package:flutter_test/flutter_test.dart';

/// Isolate/OS work needs real event-loop time; pumping only fake frames cannot
/// deliver its replies. Keep widgets on the normal fake clock, yielding real
/// time between frames rather than replacing the production storage adapter.
Future<T> storageRead<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async => (await tester.runAsync(action)) as T;

Future<void> pumpStorageAndSettle(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  var stable = 0;
  while (stable < 3) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    stable = tester.binding.hasScheduledFrame ? 0 : stable + 1;
    if (DateTime.now().isAfter(deadline)) {
      throw TestFailure(
        'UI did not settle while waiting for asynchronous storage',
      );
    }
  }
}
