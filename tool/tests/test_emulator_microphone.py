import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / 'emulator_microphone.py'
spec = importlib.util.spec_from_file_location('emulator_microphone', MODULE_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MicrophoneProfileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'original.img'
        self.output = self.root / 'profile' / 'system.img'
        self.original = b'prefix\n' + module.ORIGINAL_PROPERTY + b'\nsuffix'
        self.modified = self.original.replace(
            module.ORIGINAL_PROPERTY, module.TUNED_PROPERTY)
        self.source.write_bytes(self.original)

    def prepare(self):
        return module.prepare_image(
            self.source, self.output,
            hashlib.sha256(self.original).hexdigest(),
            hashlib.sha256(self.modified).hexdigest())

    def test_changes_only_profile_copy_and_reuses_verified_copy(self):
        self.prepare()
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(self.output.read_bytes(), self.modified)
        before = self.output.stat().st_mtime_ns
        self.prepare()
        self.assertEqual(self.output.stat().st_mtime_ns, before)

    def test_refuses_an_unknown_sdk_image(self):
        self.source.write_bytes(self.original + b'changed SDK')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_refuses_to_patch_original_through_symlink(self):
        self.output.parent.mkdir()
        self.output.symlink_to(self.source)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_refuses_unrecognized_existing_profile_without_overwriting(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b'keep this file')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.output.read_bytes(), b'keep this file')

    def test_duplicate_property_is_rejected(self):
        self.original += b'\n' + module.ORIGINAL_PROPERTY
        self.source.write_bytes(self.original)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_sdk_directory_and_data_safe_boot_arguments(self):
        sdk = self.root / 'sdk'
        original = self.root / 'sdk-images'
        original.mkdir()
        (original / 'vendor.img').write_bytes(b'vendor unchanged')
        (original / 'system.img').write_bytes(b'original system')
        profile = self.root / 'profile'
        profile.mkdir()
        image = profile / 'tuned.img'
        image.write_bytes(b'tuned system')
        directory = module.prepare_directory(original, profile / 'sysdir', image)
        self.assertEqual((directory / 'system.img').resolve(), image.resolve())
        self.assertEqual((directory / 'vendor.img').read_bytes(), b'vendor unchanged')
        command = module.boot_command(sdk, directory, 'nianxia-api36')
        self.assertEqual(command[command.index('-port') + 1], '5554')
        self.assertIn('-allow-host-audio', command)
        self.assertIn('-no-snapshot', command)
        self.assertIn('-sysdir', command)
        self.assertTrue({'-wipe-data', '-data', '-initdata', '-writable-system',
                         '-read-only'}.isdisjoint(command))

    def test_refuses_to_boot_other_system_versions_or_abis(self):
        sdk = self.root / 'sdk'
        source = sdk / 'system-images/android-36/google_apis/arm64-v8a'
        profile = self.root / 'profile'
        good = {'target': 'android-36', 'abi.type': 'arm64-v8a',
                'hw.cpu.arch': 'arm64', 'tag.id': 'google_apis',
                'image.sysdir.1': 'system-images/android-36/google_apis/arm64-v8a/'}
        module.validate_avd(good, sdk, source, profile)
        for field, value in [('target', 'android-35'), ('abi.type', 'x86_64'),
                             ('hw.cpu.arch', 'x86_64'), ('tag.id', 'google_apis_playstore'),
                             ('image.sysdir.1', 'other-sdk-image')]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.validate_avd({**good, field: value}, sdk, source, profile)
        module.validate_avd({**good, 'image.sysdir.1': str(profile / 'sysdir')},
                            sdk, source, profile)


if __name__ == '__main__':
    unittest.main()
