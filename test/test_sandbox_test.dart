import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/test_sandbox.dart';

void main() {
  test('只接受独立模型测试包的私有缓存路径', () {
    expect(
      isModelTestSandbox('/data/user/0/app.nianxia.nianxia.test/code_cache'),
      isTrue,
    );
    for (final path in [
      '/data/user/0/app.nianxia.nianxia/code_cache',
      '/data/user/0/app.nianxia.nianxia.test.other/code_cache',
      '/tmp/app.nianxia.nianxia.test/code_cache',
    ]) {
      expect(isModelTestSandbox(path), isFalse, reason: path);
    }
  });
}
