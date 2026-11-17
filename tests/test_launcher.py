import os
import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / '開始連動.command'
OPEN_APP_SOURCE = pathlib.Path(__file__).resolve().parents[1] / '開啟手燈連動.command'


class LauncherTests(unittest.TestCase):
    def run_stub(self, status, with_device=True):
        with tempfile.TemporaryDirectory(prefix='penlight-launcher-') as tmp:
            root = pathlib.Path(tmp)
            launcher = root / SOURCE.name
            launcher.write_bytes(SOURCE.read_bytes())
            stub = root / 'PenlightSync'
            stub.write_text('#!/bin/zsh\nprint -u2 "sample permission error"\nexit %d\n' % status)
            stub.chmod(0o700)
            if with_device:
                (root / 'device-id.txt').write_text('00000000-0000-0000-0000-000000000001\n')
            logs = root / 'logs'
            env = dict(os.environ, PENLIGHT_LOG_DIR=str(logs))
            result = subprocess.run(['/bin/zsh', str(launcher)], stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, env=env, timeout=5)
            log = (logs / 'latest.log').read_text()
            return result, log

    def test_failed_child_keeps_error_and_exit_status(self):
        result, log = self.run_stub(2)
        self.assertEqual(result.returncode, 2)
        self.assertIn('sample permission error', result.stdout)
        self.assertIn('代碼 2', result.stdout)
        self.assertIn('sample permission error', log)

    def test_successful_child_reports_end_and_records_output(self):
        result, log = self.run_stub(0)
        self.assertEqual(result.returncode, 0)
        self.assertIn('連動已結束', result.stdout)
        self.assertIn('sample permission error', log)

    def test_missing_device_id_explains_setup_without_running_cli(self):
        result, log = self.run_stub(0, with_device=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn('device-id.txt', result.stdout)
        self.assertNotIn('sample permission error', log)

    def test_open_app_helper_unquarantines_and_opens_local_bundle(self):
        with tempfile.TemporaryDirectory(prefix='penlight-open-helper-') as tmp:
            root = pathlib.Path(tmp)
            helper = root / OPEN_APP_SOURCE.name
            helper.write_bytes(OPEN_APP_SOURCE.read_bytes())
            app_dir = root / 'PenlightSync.app'
            app_dir.mkdir()
            open_stub = root / 'open-stub'
            opened_log = root / 'opened.txt'
            open_stub.write_text('#!/bin/zsh\nprint -r -- "$1" > "$OPENED_LOG"\n')
            open_stub.chmod(0o700)
            env = dict(os.environ, PENLIGHT_OPEN_BIN=str(open_stub), OPENED_LOG=str(opened_log))
            result = subprocess.run(['/bin/zsh', str(helper)], stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, env=env, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(opened_log.read_text().strip(), str(app_dir.resolve()))


if __name__ == '__main__':
    unittest.main()
