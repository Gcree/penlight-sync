import os
import pathlib
import pty
import select
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = pathlib.Path(__file__).resolve().parent
SYNTHETIC_UUID = "00000000-0000-0000-0000-000000000001"


class PenlightCLITests(unittest.TestCase):
    def test_compiles_and_runs_pure_self_tests(self):
        with tempfile.TemporaryDirectory(prefix="penlight-sync-test-") as temporary:
            binary = pathlib.Path(temporary) / "PenlightSync"
            subprocess.run(
                [
                    "swiftc",
                    "-parse-as-library",
                    str(SOURCES / "ScreenColor.swift"),
                    str(SOURCES / "PenlightProtocol.swift"),
                    str(SOURCES / "PenlightSync.swift"),
                    "-o",
                    str(binary),
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            result = subprocess.run(
                [str(binary), "--self-test"],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("PenlightSync self-tests passed", result.stdout)

            for args in (
                ["--replay", "00" * 16],  # no explicit target
                ["--replay", "00", "--device", SYNTHETIC_UUID],
                ["--sync", "--device", SYNTHETIC_UUID, "--palette", "/no/such/file"],  # removed palette mode
                ["--sync"],  # no explicit target
                ["--calibrate"],  # no explicit target
                ["--rgb", "GG0000", "--device", SYNTHETIC_UUID],
                ["--rgb", "FF0000"],  # no explicit target
                ["--probe", "--duration", "0"],
            ):
                invalid = subprocess.run(
                    [str(binary), *args],
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(invalid.returncode, 0, args)

            master, slave = pty.openpty()
            process = subprocess.Popen(
                [str(binary), "--stdin-self-test"],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                start_new_session=True,
                close_fds=True,
            )
            os.close(slave)

            def read_until(marker, timeout=2):
                collected = bytearray()
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([master], [], [], deadline - time.monotonic())
                    if not ready:
                        break
                    try:
                        collected.extend(os.read(master, 8192))
                    except OSError:
                        break
                    if marker in collected:
                        break
                return bytes(collected)

            try:
                os.write(master, b"0123456789abcdef0123456789abcdef\n")
                line_output = read_until(b"STDIN_DATA bytes=33")
                self.assertIn(b"STDIN_DATA bytes=33", line_output)

                # Ctrl-D on the empty canonical terminal line produces EOF.
                os.write(master, b"\x04")
                eof_output = read_until(b"STDIN_EOF")
                self.assertEqual(eof_output.count(b"STDIN_EOF"), 1)
                self.assertEqual(process.wait(timeout=2), 0)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)
                os.close(master)


if __name__ == "__main__":
    unittest.main()
