#!/usr/bin/env python3
"""Run model integration checks without installing or cleaning the real app."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

TEST_PACKAGE = 'app.nianxia.nianxia.test'
OFFICIAL_PACKAGE = 'app.nianxia.nianxia'
TARGETS = {
    'search': 'integration_test/indexed_search_test.dart',
    'storage': 'integration_test/data_upgrade_test.dart',
    'full': 'integration_test/model_flows_test.dart',
    'smoke': 'integration_test/local_models_test.dart',
    'demo': 'tool/manual_audio_demo.dart',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', default='emulator-5554')
    parser.add_argument('--target', choices=TARGETS, default='full')
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-[0-9]+', args.device):
        raise RuntimeError('Only an emulator serial is allowed')
    root = Path(__file__).resolve().parents[1]
    sdk = Path(os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME') or '')
    adb = sdk / 'platform-tools' / 'adb'
    flutter = os.environ.get('FLUTTER_BIN') or shutil.which('flutter')
    aapts = sorted((sdk / 'build-tools').glob('*/aapt'),
                   key=lambda path: tuple(int(n) for n in re.findall(r'\d+', path.parent.name)))
    if not adb.is_file() or not flutter or not aapts:
        raise RuntimeError('Set ANDROID_SDK_ROOT and FLUTTER_BIN (or put flutter on PATH)')

    def run(command, capture=False):
        return subprocess.run(command, cwd=root, check=True, text=True,
                              stdout=subprocess.PIPE if capture else None).stdout

    device_adb = [str(adb), '-s', args.device]
    if run([*device_adb, 'shell', 'getprop', 'ro.kernel.qemu'], True).strip() != '1':
        raise RuntimeError('Target is not a QEMU Android emulator')
    before = run([*device_adb, 'shell', 'pm', 'path', OFFICIAL_PACKAGE], True)
    target = TARGETS[args.target]
    run([flutter, 'build', 'apk', '--debug', '--target', target,
         '--target-platform', 'android-arm64'])
    apk = root / 'build/app/outputs/flutter-apk/app-debug.apk'
    badging = run([str(aapts[-1]), 'dump', 'badging', str(apk)], True)
    match = re.search(r"^package: name='([^']+)'", badging, re.MULTILINE)
    if match is None or match.group(1) != TEST_PACKAGE:
        raise RuntimeError(f'APK package must be {TEST_PACKAGE}; refused to install')
    # ADB -r never retries by uninstalling. Abort on any install/signature error.
    try:
        run([*device_adb, 'install', '-r', '-t', str(apk)])
        if args.target in ('full', 'smoke', 'demo'):
            run([*device_adb, 'shell', 'pm', 'grant', TEST_PACKAGE, 'android.permission.RECORD_AUDIO'])
        if args.target == 'demo':
            run([*device_adb, 'shell', 'am', 'start', '-W', '-n',
                 f'{TEST_PACKAGE}/app.nianxia.nianxia.MainActivity'])
        else:
            run([flutter, 'drive', '--debug', '--driver=test_driver/local_models_driver.dart',
                 f'--target={target}', f'--use-application-binary={apk}',
                 '-d', args.device, '--no-dds', '--keep-app-running'])
    finally:
        after = run([*device_adb, 'shell', 'pm', 'path', OFFICIAL_PACKAGE], True)
        if before != after:
            raise RuntimeError('Official app installation changed; stop and inspect')
    print(f'Passed in isolated {TEST_PACKAGE}; official installation unchanged.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
