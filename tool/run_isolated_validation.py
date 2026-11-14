#!/usr/bin/env python3
"""Build and validate disposable test apps; never install a production identity."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


TEST_ID = 'app.nianxia.nianxia.test'
FORMAL_ID = 'app.nianxia.nianxia'
CASES = {
    'capture': ('isolation-smoke', 'background-smoke', 'capture-matrix', 'deadline-auto-finalize',
                'process-kill-active', 'process-kill-query', 'kill-after-finalize', 'kill-after-source-commit'),
    'backup': ('isolation-smoke', 'cipher-smoke', 'cipher-resources', 'backup-matrix'),
    'acceptance': ('isolation-smoke', 'offline-end-to-end', 'performance', 'search-paging', 'diagnostics', 'local-jobs'),
}
TARGETS = {'capture': 'background_capture_test.dart', 'backup': 'backup_crypto_test.dart',
           'acceptance': 'app_acceptance_test.dart'}


class ValidationError(Exception):
    pass


def run(command, *, env=None, timeout=1200, allow_failure=False):
    try:
        result = subprocess.run(command, env=env, capture_output=True, text=True,
                                timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValidationError('Validation tool unavailable or timed out') from error
    if result.returncode and not allow_failure:
        # Tool output can contain VM-service credentials or private paths.
        operation = command[1] if len(command) > 1 else ''
        raise ValidationError(f'Validation tool failed: {Path(command[0]).name} {operation}')
    return result


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=('android', 'ios'))
    parser.add_argument('--device', required=True)
    parser.add_argument('--target', required=True, choices=tuple(CASES))
    parser.add_argument('--mode', default='debug', choices=('debug', 'profile', 'release'))
    parser.add_argument('--case', required=True)
    args = parser.parse_args()
    if args.case not in CASES[args.target]:
        parser.error('case is not allowed for this target')
    if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,128}', args.device) or args.device.startswith('-'):
        parser.error('invalid device identifier')
    return args


def require_result(data, run_id, case):
    if (not isinstance(data, dict) or data.get('passed') is not True
            or data.get('runId') != run_id or data.get('case') != case
            or data.get('applicationId') != TEST_ID):
        raise ValidationError('Missing or invalid guarded in-app result')


def drive_with_screen_off(drive, adb, run_id):
    """Only the disposable emulator may receive screen keys; never change its lock policy."""
    if run([*adb, 'shell', 'getprop', 'ro.kernel.qemu']).stdout.strip() != '1':
        raise ValidationError('Automatic screen-off validation requires an emulator')
    with ThreadPoolExecutor(max_workers=1) as workers:
        pending = workers.submit(drive)
        slept = False
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                response = run([*adb, 'exec-out', 'run-as', TEST_ID, 'cat',
                                f'cache/validation-progress/{run_id}.json'],
                               timeout=10, allow_failure=True)
                try:
                    data = json.loads(response.stdout)
                except ValueError:
                    data = None
                if (isinstance(data, dict) and data.get('runId') == run_id
                        and data.get('applicationId') == TEST_ID
                        and data.get('case') == 'capture-matrix'
                        and data.get('phase') == 'recording'):
                    foreground = run([*adb, 'shell', 'dumpsys', 'activity', 'activities']).stdout
                    if not re.search(r'^\s*(?:mResumedActivity:|topResumedActivity=|ResumedActivity:).*\s' + re.escape(TEST_ID) + r'/', foreground, re.MULTILINE):
                        raise ValidationError('Test app is not the resumed activity; screen keys refused')
                    slept = True  # Wake even if sending sleep itself fails.
                    run([*adb, 'shell', 'input', 'keyevent', '223'])
                    return pending.result()
                if pending.done():
                    pending.result()
                    raise ValidationError('Recording checkpoint missing; screen keys refused')
                time.sleep(.1)
            raise ValidationError('Recording checkpoint timed out; screen keys refused')
        finally:
            if slept:
                run([*adb, 'shell', 'input', 'keyevent', '224'])


KILL_PHASES = {'process-kill-active': 'active', 'process-kill-query': 'query-active',
               'kill-after-finalize': 'finalized', 'kill-after-source-commit': 'source-committed'}


def drive_with_process_kill(drive, adb, run_id, case):
    with ThreadPoolExecutor(max_workers=1) as workers:
        pending = workers.submit(drive)
        killed = False
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            response = run([*adb, 'exec-out', 'run-as', TEST_ID, 'cat',
                            f'cache/validation-progress/{run_id}.json'], timeout=10, allow_failure=True)
            try:
                data = json.loads(response.stdout)
            except ValueError:
                data = None
            if (isinstance(data, dict) and data.get('runId') == run_id
                    and data.get('applicationId') == TEST_ID and data.get('case') == case
                    and data.get('phase') == KILL_PHASES[case]):
                if not run([*adb, 'shell', 'pidof', TEST_ID], allow_failure=True).stdout.strip():
                    raise ValidationError('Test process exited before the requested kill checkpoint')
                run([*adb, 'shell', 'am', 'force-stop', TEST_ID])
                killed = True
                break
            if pending.done():
                pending.result()
                raise ValidationError('Kill checkpoint missing; no process was stopped')
            time.sleep(.1)
        if not killed:
            raise ValidationError('Kill checkpoint timed out; no process was stopped')
        try:
            pending.result()
        except ValidationError:
            pass  # The first driver is expected to lose the stopped process.
        if run([*adb, 'shell', 'pidof', TEST_ID], allow_failure=True).stdout.strip():
            raise ValidationError('Test process did not terminate')
        drive()  # Same binary/nonce; persistent checkpoint chooses recovery stage.


def main():
    args = parse_args()
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    flutter = os.environ.get('FLUTTER_BIN') or shutil.which('flutter')
    if not flutter:
        raise ValidationError('Set FLUTTER_BIN or put flutter on PATH')
    try:
        devices = json.loads(run([flutter, 'devices', '--machine'], timeout=60).stdout)
    except (ValueError, TypeError) as error:
        raise ValidationError('Cannot verify requested device') from error
    device = next((d for d in devices if d.get('id') == args.device), None)
    if device is None or not str(device.get('targetPlatform', '')).startswith(args.platform):
        raise ValidationError('Requested device is unavailable or has a different platform')
    if args.platform == 'ios' and args.mode == 'release':
        raise ValidationError('iOS release installation requires a verified native-device runner; refused')
    if args.mode == 'release' and (args.case in KILL_PHASES or args.case == 'capture-matrix'):
        raise ValidationError('Automatic capture faults require the debug/profile orchestrator; release refused')
    target = 'integration_test/' + ('isolation_smoke_test.dart' if args.case == 'isolation-smoke'
                                    else 'deadline_capture_test.dart' if args.case == 'deadline-auto-finalize' else 'search_paging_test.dart' if args.case == 'search-paging' else 'local_jobs_test.dart' if args.case == 'local-jobs' else 'diagnostics_test.dart' if args.case == 'diagnostics' else TARGETS[args.target])
    if not (root / target).is_file():
        raise ValidationError('Requested test entry point is not implemented')
    run_id = str(uuid.uuid4())
    print(f'Validation run: {run_id}', flush=True)
    definitions = [f'--dart-define=VALIDATION_RUN_ID={run_id}',
                   f'--dart-define=VALIDATION_CASE={args.case}']
    adb = None
    before = None
    if args.platform == 'android':
        sdk_value = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
        if not sdk_value:
            raise ValidationError('Set ANDROID_SDK_ROOT')
        sdk = Path(sdk_value)
        adb = [str(sdk / 'platform-tools/adb'), '-s', args.device]
        aapts = sorted((sdk / 'build-tools').glob('*/aapt'),
                       key=lambda p: tuple(int(n) for n in re.findall(r'\d+', p.parent.name)))
        if not aapts:
            raise ValidationError('Android build-tools unavailable')
        before = run([*adb, 'shell', 'pm', 'path', FORMAL_ID]).stdout
    try:
        command = [flutter, 'build', 'apk' if adb else 'ios', f'--{args.mode}',
                   '--target', target, *definitions]
        if adb:
            command += ['--target-platform', 'android-arm64']
        else:
            command += ['--flavor', 'isolated']
            if device.get('emulator'):
                command += ['--simulator']
        run(command)
        if adb:
            artifact = root / f'build/app/outputs/flutter-apk/app-{args.mode}.apk'
            badging = run([str(aapts[-1]), 'dump', 'badging', str(artifact)]).stdout
            identity = re.search(r"^package: name='([^']+)'", badging, re.MULTILINE)
            if identity is None or identity.group(1) != TEST_ID:
                raise ValidationError('APK identity is not the isolated test package; refused')
            run([*adb, 'install', '-r', '-t', str(artifact)])
            if args.target == 'capture' and args.case != 'isolation-smoke':
                run([*adb, 'shell', 'pm', 'grant', TEST_ID, 'android.permission.RECORD_AUDIO'])
        else:
            destination = 'iphonesimulator' if device.get('emulator') else 'iphoneos'
            artifact = root / 'build/ios' / destination / 'Runner.app'
            try:
                identity = plistlib.loads((artifact / 'Info.plist').read_bytes())['CFBundleIdentifier']
            except (OSError, ValueError, KeyError) as error:
                raise ValidationError('Cannot read built iOS identity; refused') from error
            if identity != TEST_ID:
                raise ValidationError('iOS identity is not the isolated test bundle; refused')
        if args.mode == 'release':
            run([*adb, 'shell', 'am', 'start', '-W', '-n',
                 f'{TEST_ID}/app.nianxia.nianxia.MainActivity'])
            deadline = time.monotonic() + 240
            data = None
            while time.monotonic() < deadline:
                response = run([*adb, 'shell', 'content', 'read', '--uri',
                                f'content://{TEST_ID}.validation/{run_id}'],
                               timeout=10, allow_failure=True)
                if response.returncode == 0:
                    try:
                        data = json.loads(response.stdout)
                    except ValueError:
                        pass
                    if data is not None:
                        break
                time.sleep(0.5)
            require_result(data, run_id, args.case)
        else:
            with tempfile.TemporaryDirectory(prefix='nianxia-validation-result-') as work:
                result_file = Path(work) / 'result.json'
                env = dict(os.environ, NIANXIA_VALIDATION_RESULT=str(result_file),
                           NIANXIA_VALIDATION_RUN_ID=run_id)
                drive = [flutter, 'drive', f'--{args.mode}',
                         '--driver=test_driver/isolated_validation_driver.dart',
                         f'--target={target}', f'--use-application-binary={artifact}',
                         '-d', args.device, '--no-dds', '--keep-app-running', *definitions]
                if not adb:
                    drive += ['--flavor', 'isolated']
                if args.case == 'capture-matrix':
                    if not adb:
                        raise ValidationError('Automatic screen-off currently requires Android emulator')
                    drive_with_screen_off(lambda: run(drive, env=env), adb, run_id)
                elif args.case in KILL_PHASES:
                    if not adb:
                        raise ValidationError('Process kill validation currently requires Android')
                    drive_with_process_kill(lambda: run(drive, env=env, timeout=120), adb, run_id, args.case)
                else:
                    run(drive, env=env)
                try:
                    data = json.loads(result_file.read_text())
                except (OSError, ValueError) as error:
                    raise ValidationError('Guarded test result missing') from error
                require_result(data, run_id, args.case)
    finally:
        if adb and before is not None:
            after = run([*adb, 'shell', 'pm', 'path', FORMAL_ID]).stdout
            if before != after:
                raise ValidationError('Formal installation changed; stop and inspect')
    print(f'Passed isolated validation: {args.target}/{args.case} ({args.mode}); formal data not read.')


if __name__ == '__main__':
    try:
        main()
    except ValidationError as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
