import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('validation_runner', Path(__file__).resolve().parents[1] / 'run_isolated_validation.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class CaptureScreenOffTest(unittest.TestCase):
    def exercise(self, foreground=True, emulator=True, failure=False):
        calls = []
        def command(args, **kwargs):
            calls.append(args)
            output = ''
            if 'getprop' in args:
                output = '1' if emulator else '0'
            elif 'dumpsys' in args:
                output = '  topResumedActivity=ActivityRecord{0 ' + (runner.TEST_ID if foreground else runner.FORMAL_ID) + '/.MainActivity}'
            elif 'cat' in args:
                output = json.dumps({'applicationId': runner.TEST_ID, 'runId': 'nonce', 'phase': 'recording', 'case': 'capture-matrix'})
            return subprocess.CompletedProcess(args, 0, output, '')
        def drive():
            # Wait until orchestration has reached sleep or refused the target.
            import time
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and not any('223' in c for c in calls):
                time.sleep(.01)
                if not foreground or not emulator:
                    return
            if failure:
                raise runner.ValidationError('controlled driver failure')
        with patch.object(runner, 'run', side_effect=command):
            try:
                runner.drive_with_screen_off(drive, ['adb', '-s', 'test'], 'nonce')
            except runner.ValidationError:
                if foreground and emulator and not failure:
                    raise
        return calls

    def test_sleeps_only_after_current_run_checkpoint_and_wakes_on_success(self):
        calls = self.exercise()
        self.assertTrue(any('223' in c for c in calls))
        self.assertTrue(any('224' in c for c in calls))
        self.assertLess(next(i for i,c in enumerate(calls) if 'cat' in c), next(i for i,c in enumerate(calls) if '223' in c))

    def test_never_sends_screen_keys_to_physical_or_other_foreground_app(self):
        for kwargs in ({'emulator': False}, {'foreground': False}):
            with self.subTest(kwargs=kwargs):
                self.assertFalse(any('keyevent' in c for c in self.exercise(**kwargs)))

    def test_driver_failure_still_wakes_test_emulator(self):
        calls = self.exercise(failure=True)
        self.assertTrue(any('224' in c for c in calls))


class CaptureProcessKillTest(unittest.TestCase):
    def test_only_checkpointed_test_package_is_stopped_then_relaunched(self):
        calls=[];launches=0
        def command(args,**kwargs):
            calls.append(args)
            out=''
            if 'cat' in args:
                out=json.dumps({'applicationId':runner.TEST_ID,'runId':'nonce','phase':'active','case':'process-kill-active'})
            elif 'pidof' in args:out='1234' if not any('force-stop' in c for c in calls) else ''
            return subprocess.CompletedProcess(args,0,out,'')
        def drive():
            nonlocal launches
            launches+=1
            if launches==1:
                import time
                while not any('force-stop' in c for c in calls):time.sleep(.01)
                raise runner.ValidationError('expected killed driver')
        with patch.object(runner,'run',side_effect=command):
            runner.drive_with_process_kill(drive,['adb','-s','test'],'nonce','process-kill-active')
        self.assertEqual(launches,2)
        stops=[c for c in calls if 'force-stop' in c]
        self.assertEqual(len(stops),1);self.assertEqual(stops[0][-1],runner.TEST_ID)
        self.assertFalse(any('clear' in c or 'uninstall' in c for c in calls))


if __name__ == '__main__':
    unittest.main()
