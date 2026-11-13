import 'dart:io';

import 'package:path/path.dart' as p;

bool isModelTestSandbox(String directory) => RegExp(
  r'^/data/(?:user/0|data)/app\.nianxia\.nianxia\.test/(?:code_cache|cache)(?:/|$)',
).hasMatch(p.normalize(directory));

void requireModelTestSandbox() {
  if (!Platform.isAndroid ||
      !isModelTestSandbox(Directory.systemTemp.resolveSymbolicLinksSync())) {
    throw StateError('模型集成测试只允许在独立的 app.nianxia.nianxia.test 中运行。');
  }
}
