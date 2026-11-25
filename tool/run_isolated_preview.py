#!/usr/bin/env python3
"""Build a hands-on isolated APK, optionally launch it on a verified emulator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import time
import uuid

from run_isolated_validation import TEST_ID, ValidationError, run, formal_installation


def require_test_apk(badging):
    match = re.search(r"^package: name='([^']+)'", badging, re.MULTILINE)
    if match is None or match.group(1) != TEST_ID:
        raise ValidationError('Refused non-test preview APK')
    if '念下·测试' not in badging:
        raise ValidationError('Missing isolated application label')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', default='emulator-5554')
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-\d+', args.device):
        raise ValidationError('Preview auto-launch requires an emulator')
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    sdk = Path(os.environ.get('ANDROID_SDK_ROOT', ''))
    flutter = os.environ.get('FLUTTER_BIN') or shutil.which('flutter')
    aapts = sorted((sdk / 'build-tools').glob('*/aapt'), key=lambda p: tuple(map(int, re.findall(r'\d+', p.parent.name))))
    if not flutter or not aapts:
        raise ValidationError('Flutter and Android build tools are required')
    adb = [str(sdk / 'platform-tools/adb'), '-s', args.device]
    if not args.build_only and run([*adb, 'shell', 'getprop', 'ro.kernel.qemu']).stdout.strip() != '1':
        raise ValidationError('Preview auto-launch refused a physical device')
    before = None if args.build_only else formal_installation(adb)
    run_id = str(uuid.uuid4())
    digest = hashlib.sha256()
    paths = set()
    for pattern in ('lib/**/*.dart', 'android/app/src/**/*.kt', 'android/app/src/**/*.xml', 'assets/models.json', 'pubspec.yaml', 'pubspec.lock', 'integration_test/preview/main.dart'):
        paths.update(root.glob(pattern))
    for path in sorted(paths):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    source = digest.hexdigest()
    output = root / 'build' / 'isolated-preview' / run_id
    output.mkdir(parents=True)
    try:
        run([flutter, 'build', 'apk', '--profile', '--target', 'integration_test/preview/main.dart', '--target-platform', 'android-arm64', f'--dart-define=UI_PREVIEW_RUN_ID={run_id}', f'--dart-define=UI_PREVIEW_SOURCE_DIGEST={source}'])
        built = root / 'build/app/outputs/flutter-apk/app-profile.apk'
        require_test_apk(run([str(aapts[-1]), 'dump', 'badging', str(built)]).stdout)
        artifact = output / 'nianxia-continuous-preview.apk'
        shutil.copyfile(built, artifact)
        metadata = {'applicationId': TEST_ID, 'runId': run_id, 'sourceDigest': source, 'apkSha256': hashlib.sha256(artifact.read_bytes()).hexdigest(), 'entry': 'integration_test/preview/main.dart', 'mode': 'profile', 'ordinaryCapture': True}
        (output / 'manifest.json').write_text(json.dumps(metadata, indent=2) + '\n')
        if not args.build_only:
            run([*adb, 'install', '-r', '-t', str(artifact)])
            run([*adb, 'shell', 'pm', 'grant', TEST_ID, 'android.permission.RECORD_AUDIO'])
            run([*adb, 'shell', 'am', 'start', '-W', '-n', f'{TEST_ID}/app.nianxia.nianxia.MainActivity'])
            until = time.monotonic() + 120
            while time.monotonic() < until:
                response = run([*adb, 'exec-out', 'run-as', TEST_ID, 'cat', f'cache/continuous-preview/{run_id}/ready.json'], allow_failure=True, timeout=10)
                try:
                    ready = json.loads(response.stdout)
                except ValueError:
                    ready = {}
                if ready.get('applicationId') == TEST_ID and ready.get('runId') == run_id and ready.get('sourceDigest') == source and ready.get('ready') is True:
                    (output / 'ready.json').write_text(json.dumps(ready, indent=2) + '\n')
                    break
                time.sleep(.5)
            else:
                raise ValidationError('Preview did not reach verified ready checkpoint')
        print(artifact)
        print('Hands-on isolated preview ready; no testWidgets or automatic completion.')
    finally:
        if before is not None and before != formal_installation(adb):
            raise ValidationError('Formal installation changed')


if __name__ == '__main__':
    try:
        main()
    except ValidationError as error:
        raise SystemExit(str(error)) from error
