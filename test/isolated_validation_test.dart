import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/isolated_validation.dart';

void main() {
  const app = 'app.nianxia.nianxia.test';
  const root = '/data/user/0/$app/cache';
  const android = {
    'applicationId': app,
    'cacheRoot': root,
    'temporaryRoots': [root, '/data/user/0/$app/code_cache'],
  };

  test('真实测试包及其私有缓存才能通过验证边界', () {
    expect(
      isIsolatedValidationIdentity(
        android,
        platform: 'android',
        temporaryPath: '/data/user/0/$app/code_cache',
      ),
      isTrue,
    );
    for (final change in [
      {...android, 'applicationId': 'app.nianxia.nianxia'},
      {...android, 'cacheRoot': '/'},
      {...android, 'temporaryRoots': ['/tmp']},
    ]) {
      expect(
        isIsolatedValidationIdentity(
          change,
          platform: 'android',
          temporaryPath: '/data/user/0/$app/code_cache',
        ),
        isFalse,
      );
    }
    expect(
      isIsolatedValidationIdentity(
        android,
        platform: 'android',
        temporaryPath: '/data/user/0/$app/code_cache.other',
      ),
      isFalse,
    );
  });

  test('iOS同时核对原生Bundle身份和真实容器路径', () {
    const home = '/private/var/mobile/Containers/Data/Application/'
        'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
    const ios = {
      'applicationId': app,
      'cacheRoot': '$home/Library/Caches',
      'temporaryRoots': ['$home/tmp'],
    };
    expect(
      isIsolatedValidationIdentity(ios, platform: 'ios', temporaryPath: '$home/tmp'),
      isTrue,
    );
    expect(
      isIsolatedValidationIdentity(
        {...ios, 'applicationId': 'app.nianxia.nianxia'},
        platform: 'ios',
        temporaryPath: '$home/tmp',
      ),
      isFalse,
    );
    expect(
      isIsolatedValidationIdentity(
        ios,
        platform: 'ios',
        temporaryPath: '$home/tmp/../../outside',
      ),
      isFalse,
    );
  });
}
