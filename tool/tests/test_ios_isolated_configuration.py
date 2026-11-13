import json
from pathlib import Path
import shutil
import subprocess
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('plutil'), 'OpenStep build settings require Apple plutil')
class IosIsolatedConfigurationTest(unittest.TestCase):
    def test_isolated_schemes_resolve_test_bundle_without_changing_runner_identity(self):
        parsed = subprocess.run(['plutil', '-convert', 'json', '-o', '-',
                                 str(ROOT / 'ios/Runner.xcodeproj/project.pbxproj')],
                                check=True, capture_output=True, text=True)
        objects = json.loads(parsed.stdout)['objects']
        runner = next(v for v in objects.values()
                      if v.get('isa') == 'PBXNativeTarget' and v.get('name') == 'Runner')
        ids = objects[runner['buildConfigurationList']]['buildConfigurations']
        configs = {objects[i]['name']: objects[i]['buildSettings'] for i in ids}
        for mode in ('Debug', 'Profile', 'Release'):
            self.assertEqual(configs[mode]['PRODUCT_BUNDLE_IDENTIFIER'], 'app.nianxia.nianxia')
            self.assertIn(f'{mode}-isolated', configs, '缺少隔离构建配置')
            self.assertEqual(configs[f'{mode}-isolated']['PRODUCT_BUNDLE_IDENTIFIER'],
                             'app.nianxia.nianxia.test')
        scheme = ROOT / 'ios/Runner.xcodeproj/xcshareddata/xcschemes/isolated.xcscheme'
        self.assertTrue(scheme.exists(), '缺少共享隔离scheme')
        tree = ET.parse(scheme)
        self.assertEqual(tree.find('LaunchAction').attrib['buildConfiguration'], 'Debug-isolated')
        self.assertEqual(tree.find('ArchiveAction').attrib['buildConfiguration'], 'Release-isolated')


if __name__ == '__main__':
    unittest.main()
