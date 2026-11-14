import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('offline_runner', Path(__file__).resolve().parents[1] / 'run_isolated_validation.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class OfflineValidationTest(unittest.TestCase):
    def exercise(self, phone=False, failure=False):
        calls = []
        state = {'airplane': '0', 'wifi': 'enabled'}
        def run(args, **kwargs):
            calls.append(args)
            if 'getprop' in args:
                out = '0' if phone else '1'
            elif args[-3:] == ['global', 'airplane_mode_on', 'unused']:
                raise AssertionError('Malformed settings read')
            elif 'settings' in args:
                out = state['airplane']
            elif 'status' in args:
                out = 'Wifi is ' + state['wifi']
            elif 'airplane-mode' in args:
                state['airplane'] = '1' if args[-1] == 'enable' else '0'
                out = ''
            elif 'wifi' in args:
                state['wifi'] = 'disabled' if args[-1] == 'disable' else 'enabled'
                out = ''
            elif 'connectivity' in args:
                if failure: raise runner.ValidationError('controlled disconnect failure')
                out = 'Active default network: none'
            else: out = ''
            return subprocess.CompletedProcess(args, 0, out, '')
        with patch.object(runner, 'run', side_effect=run):
            if phone or failure:
                with self.assertRaises(runner.ValidationError):
                    runner.disconnect_validation_emulator(['adb', '-s', 'test'])
            else:
                snapshot = runner.disconnect_validation_emulator(['adb', '-s', 'test'])
                self.assertEqual(state, {'airplane': '1', 'wifi': 'disabled'})
                runner.restore_validation_network(['adb', '-s', 'test'], snapshot)
        self.assertEqual(state, {'airplane': '0', 'wifi': 'enabled'})
        return calls

    def test_restores_exact_original_states_after_success(self):
        self.exercise()

    def test_restores_after_disconnect_failure(self):
        self.exercise(failure=True)

    def test_never_changes_real_phone_settings(self):
        calls = self.exercise(phone=True)
        self.assertFalse(any('airplane-mode' in call or 'svc' in call for call in calls))
