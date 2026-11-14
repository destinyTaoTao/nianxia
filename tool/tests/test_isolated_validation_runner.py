import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / 'run_isolated_validation.py'


class IsolatedValidationRunnerTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'tool').mkdir()
        if RUNNER.exists():
            shutil.copyfile(RUNNER, self.root / 'tool' / RUNNER.name)
        for target in ('isolation_smoke_test.dart', 'background_capture_test.dart',
                       'backup_crypto_test.dart', 'app_acceptance_test.dart', 'ui_flows_test.dart'):
            path = self.root / 'integration_test' / target
            path.parent.mkdir(exist_ok=True)
            path.write_text('// controlled build target\n')
        self.log = self.root / 'commands.jsonl'
        self.env = dict(os.environ, CALL_LOG=str(self.log), APP_ID='app.nianxia.nianxia.test')
        self.env['FLUTTER_BIN'] = str(self.root / 'flutter')
        self.env['ANDROID_SDK_ROOT'] = str(self.root / 'android')
        self.stub(self.root / 'flutter', '''
import plistlib
if 'devices' in sys.argv:
 print(json.dumps([{'id':'emulator-5554','targetPlatform':'android-arm64','emulator':True},
                   {'id':'ios-test-id','targetPlatform':'ios','emulator':False}]))
elif 'build' in sys.argv:
 if 'apk' in sys.argv:
  p=Path('build/app/outputs/flutter-apk/app-debug.apk'); p.parent.mkdir(parents=True,exist_ok=True); p.touch()
 else:
  p=Path('build/ios/iphoneos/Runner.app'); p.mkdir(parents=True,exist_ok=True)
  (p/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':os.environ['APP_ID']}))
elif 'drive' in sys.argv:
 if os.environ.get('DRIVE_EXIT') == '1': sys.exit(1)
 Path(os.environ['NIANXIA_VALIDATION_RESULT']).write_text(json.dumps({'passed':True,'runId':os.environ['NIANXIA_VALIDATION_RUN_ID'],'case':'isolation-smoke','applicationId':os.environ['APP_ID']}))
''')
        self.stub(self.root / 'android/build-tools/36.0.0/aapt', '''
print("package: name='"+os.environ['APP_ID']+"' versionCode='1'")
''')
        self.stub(self.root / 'android/platform-tools/adb', '''
if 'path' in sys.argv: print('package:/data/app/formal/base.apk')
elif 'install' in sys.argv: sys.exit(int(os.environ.get('INSTALL_EXIT','0')))
elif 'read' in sys.argv and os.environ.get('FAKE_RELEASE_CASE'):
 print(json.dumps({'passed':True,'runId':sys.argv[-1].split('/')[-1],'case':os.environ['FAKE_RELEASE_CASE'],'applicationId':os.environ['APP_ID']}))
''')

    def stub(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'#!{sys.executable}\nimport os,sys,json\nfrom pathlib import Path\n'
                        "with open(os.environ['CALL_LOG'],'a') as f: f.write(json.dumps(sys.argv)+'\\n')\n" + body)
        path.chmod(0o755)

    def invoke(self, *args):
        path = self.root / 'tool' / RUNNER.name
        self.assertTrue(path.exists(), '缺少受保护的跨平台验证 runner')
        return subprocess.run([sys.executable, str(path), '--platform', 'android',
                               '--device', 'emulator-5554', '--target', 'capture',
                               '--mode', 'debug', '--case', 'isolation-smoke', *args],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_android_success_checks_artifact_and_never_installs_formal_package(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        install = next(i for i, c in enumerate(calls) if 'install' in c)
        inspect = next(i for i, c in enumerate(calls) if 'badging' in c)
        self.assertLess(inspect, install)
        self.assertTrue(any('drive' in c and '--keep-app-running' in c for c in calls))
        self.assertFalse(any('grant' in c or 'uninstall' in c or 'clear' in c for c in calls))

    def test_formal_android_artifact_is_rejected_before_install(self):
        self.env['APP_ID'] = 'app.nianxia.nianxia'
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('identity', result.stderr)
        self.assertFalse(any('install' in c or 'drive' in c for c in self.calls()))

    def test_absent_device_is_rejected_before_build_or_install(self):
        result = self.invoke('--device', 'unconnected-device')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('build' in c or 'install' in c for c in self.calls()))

    def test_unknown_case_is_rejected_before_any_tool(self):
        result = self.invoke('--case', 'arbitrary-operation')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_signature_failure_never_falls_back_to_uninstall(self):
        self.env['INSTALL_EXIT'] = '1'
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum('install' in c for c in self.calls()), 1)
        self.assertFalse(any('uninstall' in c or 'clear' in c or 'drive' in c for c in self.calls()))
        self.assertEqual(sum('path' in c for c in self.calls()), 2)

    def test_driver_failure_still_checks_formal_installation(self):
        self.env['DRIVE_EXIT'] = '1'
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum('path' in c for c in self.calls()), 2)

    def test_fault_cases_without_release_orchestrator_are_rejected_before_build(self):
        self.env['FAKE_RELEASE_CASE']='process-kill-active'
        result=self.invoke('--mode','release','--case','process-kill-active')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any('build' in c or 'install' in c for c in self.calls()))

    def test_ui_case_grants_microphone_only_after_verified_isolated_install(self):
        self.env['FAKE_RELEASE_CASE'] = 'ui-flows'
        result = self.invoke('--target', 'acceptance', '--mode', 'release', '--case', 'ui-flows')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        inspect = next(i for i, c in enumerate(calls) if 'badging' in c)
        install = next(i for i, c in enumerate(calls) if 'install' in c)
        grant = next(i for i, c in enumerate(calls) if 'grant' in c)
        self.assertLess(inspect, install)
        self.assertLess(install, grant)
        self.assertIn('app.nianxia.nianxia.test', calls[grant])
        self.env['APP_ID'] = 'app.nianxia.nianxia'
        self.log.unlink()
        result = self.invoke('--target', 'acceptance', '--mode', 'release', '--case', 'ui-flows')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('install' in c or 'grant' in c for c in self.calls()))

    def test_ios_uses_actual_bundle_identifier_and_isolated_flavor(self):
        result = self.invoke('--platform', 'ios', '--device', 'ios-test-id')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any('build' in c and '--flavor' in c and 'isolated' in c for c in self.calls()))
        self.assertFalse(any('install' in c for c in self.calls()))
        self.env['APP_ID'] = 'app.nianxia.nianxia'
        self.log.unlink()
        result = self.invoke('--platform', 'ios', '--device', 'ios-test-id')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('identity', result.stderr)
        self.assertFalse(any('drive' in c for c in self.calls()))


if __name__ == '__main__':
    unittest.main()
