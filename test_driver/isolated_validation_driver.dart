import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final output = Platform.environment['NIANXIA_VALIDATION_RESULT'];
    if (output == null) throw StateError('必须通过受保护的验证 runner 启动。');
    await File(output).writeAsString(jsonEncode(data), flush: true);
  },
);
