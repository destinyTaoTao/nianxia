import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';

import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('独立应用私有库写入后可重开，正式应用不可作为目标', (tester) async {
    await requireIsolatedValidation();
    final directory = await Directory.systemTemp.createTemp('nianxia-isolation-');
    Notebook? book;
    try {
      book = await Notebook.open(directory);
      final saved = await book.saveText('隔离验证夹具');
      await book.close();
      book = await Notebook.open(directory);
      expect((await book.get(saved.id))?.body, '隔离验证夹具');
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {'reopenedRecords': 1},
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      await book?.close();
      await directory.delete(recursive: true);
    }
  });
}
