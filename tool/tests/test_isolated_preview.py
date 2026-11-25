import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
spec = importlib.util.spec_from_file_location('isolated_preview', Path(__file__).resolve().parents[1] / 'run_isolated_preview.py')
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


class PreviewIdentityTest(unittest.TestCase):
    def test_rejects_formal_or_missing_identity_and_missing_label(self):
        for value in ("package: name='app.nianxia.nianxia'\n念下·测试", '念下·测试', "package: name='app.nianxia.nianxia.test'"):
            with self.assertRaises(preview.ValidationError):
                preview.require_test_apk(value)

    def test_accepts_only_test_identity_with_distinct_label(self):
        preview.require_test_apk("package: name='app.nianxia.nianxia.test' versionCode='1'\napplication-label:'念下·测试'")
