import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / 'run_android_model_tests.py'


class ModelRunnerSafetyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'tool').mkdir()
        if RUNNER.exists():
            shutil.copyfile(RUNNER, self.root / 'tool' / RUNNER.name)
        self.log = self.root / 'commands.jsonl'
        self.env = dict(os.environ, CALL_LOG=str(self.log), APK_ID='app.nianxia.nianxia.test', QEMU='1')
        sdk = self.root / 'sdk'
        self.env['ANDROID_SDK_ROOT'] = str(sdk)
        self.env['FLUTTER_BIN'] = str(self.root / 'flutter')
        self.stub(self.root / 'flutter', '''
if 'build' in sys.argv:
 p=Path('build/app/outputs/flutter-apk/app-debug.apk'); p.parent.mkdir(parents=True,exist_ok=True); p.touch()
elif 'drive' in sys.argv: sys.exit(int(os.environ.get('DRIVE_EXIT','0')))
''')
        self.stub(sdk / 'build-tools' / '36.0.0' / 'aapt', "print(\"package: name='\"+os.environ['APK_ID']+\"' versionCode='1'\")")
        self.stub(sdk / 'platform-tools' / 'adb', '''
if 'getprop' in sys.argv: print(os.environ['QEMU'])
elif 'install' in sys.argv: sys.exit(int(os.environ.get('INSTALL_EXIT','0')))
elif 'grant' in sys.argv: sys.exit(int(os.environ.get('GRANT_EXIT','0')))
elif 'path' in sys.argv: print('package:/data/app/official/base.apk')
''')

    def stub(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'#!{sys.executable}\nimport os,sys,json\nfrom pathlib import Path\n'
                        "with open(os.environ['CALL_LOG'],'a') as f: f.write(json.dumps(sys.argv)+'\\n')\n" + body)
        path.chmod(0o755)

    def run_runner(self, *args):
        return subprocess.run([sys.executable, str(self.root / 'tool' / RUNNER.name), *args],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_success_only_installs_checked_test_apk_and_keeps_it(self):
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        drive = next(call for call in calls if 'drive' in call)
        self.assertIn('--keep-app-running', drive)
        self.assertIn('--debug', drive)
        self.assertIn('emulator-5554', drive)
        self.assertTrue(any('install' in call and '-r' in call for call in calls))
        grants = [call for call in calls if 'grant' in call]
        self.assertEqual(len(grants), 1)
        self.assertIn('app.nianxia.nianxia.test', grants[0])
        self.assertFalse(any('uninstall' in call or 'clear' in call for call in calls))

    def test_official_package_apk_is_rejected_before_any_install_or_drive(self):
        self.env['APK_ID'] = 'app.nianxia.nianxia'
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('APK package', result.stderr)
        self.assertFalse(any('install' in call or 'drive' in call for call in self.calls()))

    def test_demo_opens_isolated_app_without_test_driver(self):
        result = self.run_runner('--target', 'demo')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any('app.nianxia.nianxia.test/app.nianxia.nianxia.MainActivity' in call for call in self.calls()))
        self.assertFalse(any('drive' in call for call in self.calls()))
        self.assertEqual(sum('path' in call for call in self.calls()), 2)

    def test_indexed_search_target_never_requests_microphone_permission(self):
        result = self.run_runner('--target', 'search')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        build = next(call for call in calls if 'build' in call)
        self.assertIn('integration_test/indexed_search_test.dart', build)
        self.assertFalse(any('grant' in call or 'uninstall' in call or 'clear' in call for call in calls))
        self.assertEqual(sum('path' in call for call in calls), 2)

    def test_physical_serial_rejected_before_any_tool_call(self):
        result = self.run_runner('--device', 'physical-phone')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('emulator', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_emulator_shaped_serial_with_non_qemu_device_is_rejected(self):
        self.env['QEMU'] = '0'
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('QEMU', result.stderr)
        self.assertFalse(any('install' in call or 'drive' in call for call in self.calls()))

    def test_install_failure_does_not_fall_back_to_uninstall(self):
        self.env['INSTALL_EXIT'] = '1'
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any('install' in call for call in self.calls()))
        self.assertFalse(any('uninstall' in call or 'clear' in call or 'drive' in call for call in self.calls()))
        self.assertEqual(sum('path' in call for call in self.calls()), 2)

    def test_grant_and_driver_failure_still_check_official_installation(self):
        for failure in ['GRANT_EXIT', 'DRIVE_EXIT']:
            with self.subTest(failure=failure):
                self.log.unlink(missing_ok=True)
                self.env[failure] = '1'
                result = self.run_runner()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(sum('path' in call for call in self.calls()), 2)
                self.env.pop(failure)


if __name__ == '__main__':
    unittest.main()
