import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PREFLIGHT = Path(__file__).resolve().parents[1] / 'validation_preflight.py'


class ValidationPreflightTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / 'commands.jsonl'
        self.env = dict(os.environ, CALL_LOG=str(self.log))
        self.env['PATH'] = str(self.root / 'bin')
        self.env['FLUTTER_BIN'] = str(self.root / 'flutter/bin/flutter')
        self.env['ANDROID_SDK_ROOT'] = str(self.root / 'android')
        self.stub(Path(self.env['FLUTTER_BIN']), 'print("unused")')
        version = self.root / 'flutter/bin/cache/flutter.version.json'
        version.parent.mkdir(parents=True)
        version.write_text(json.dumps({'flutterVersion': '3.47.9', 'dartSdkVersion': '3.13.7'}))
        self.stub(self.root / 'android/platform-tools/adb', 'print("unused")')
        self.stub(self.root / 'android/build-tools/36.0.0/aapt', 'print("unused")')
        self.stub(self.root / 'bin/xcode-select', 'print(os.environ.get("XCODE_DIR", "/Library/Developer/CommandLineTools"))')
        self.stub(self.root / 'bin/xcrun', '''
if os.environ.get('IOS_SDK') == '1': print('/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk')
else:
 print('sensitive-stderr-sentinel', file=sys.stderr); sys.exit(1)
''')

    def stub(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'#!{sys.executable}\nimport os,sys,json\n'
                        "with open(os.environ['CALL_LOG'],'a') as f: f.write(json.dumps(sys.argv)+'\\n')\n" + body)
        path.chmod(0o755)

    def probe(self):
        self.assertTrue(PREFLIGHT.exists(), '缺少只读环境检查入口')
        result = subprocess.run([sys.executable, str(PREFLIGHT), '--json'], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('sensitive-stderr-sentinel', result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_command_line_tools_do_not_count_as_ios_build_environment(self):
        result = self.probe()
        self.assertEqual(result['flutter']['version'], '3.47.9')
        self.assertTrue(result['android']['sdkAvailable'])
        self.assertFalse(result['ios']['sdkAvailable'])
        self.assertFalse(result['ios']['readyForBuild'])

    def test_full_xcode_requires_an_actual_iphoneos_sdk_probe(self):
        self.env['XCODE_DIR'] = '/Applications/Xcode.app/Contents/Developer'
        self.env['IOS_SDK'] = '1'
        result = self.probe()
        self.assertTrue(result['ios']['sdkAvailable'])
        self.assertTrue(result['ios']['readyForBuild'])
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertTrue(any('--show-sdk-path' in call for call in calls))
        self.assertFalse(any(arg in ('install', 'uninstall', 'clear', '--switch')
                             for call in calls for arg in call))

    def test_missing_android_sdk_is_reported_without_creation(self):
        missing = self.root / 'missing-sdk'
        self.env['ANDROID_SDK_ROOT'] = str(missing)
        result = self.probe()
        self.assertFalse(result['android']['sdkAvailable'])
        self.assertFalse(missing.exists())


if __name__ == '__main__':
    unittest.main()
