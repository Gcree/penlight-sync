import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

SOURCES = pathlib.Path(__file__).resolve().parents[1]
DOTNET = shutil.which("dotnet") or str(pathlib.Path.home() / ".dotnet" / "dotnet")


class MacAppTests(unittest.TestCase):
    def test_gui_sources_compile(self):
        with tempfile.TemporaryDirectory(prefix="penlight-gui-test-") as temporary:
            subprocess.run(
                [
                    "swiftc",
                    "-parse-as-library",
                    str(SOURCES / "ScreenColor.swift"),
                    str(SOURCES / "PenlightProtocol.swift"),
                    str(SOURCES / "PenlightApp" / "LightEngine.swift"),
                    str(SOURCES / "PenlightApp" / "BeatDetector.swift"),
                    str(SOURCES / "PenlightApp" / "SystemAudioMonitor.swift"),
                    str(SOURCES / "PenlightApp" / "RegionSelector.swift"),
                    str(SOURCES / "PenlightApp" / "ScreenStream.swift"),
                    str(SOURCES / "PenlightApp" / "PenlightController.swift"),
                    str(SOURCES / "PenlightApp" / "UpdateChecker.swift"),
                    str(SOURCES / "PenlightApp" / "PenlightApp.swift"),
                    "-o",
                    str(pathlib.Path(temporary) / "PenlightSyncApp"),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

    def compile_and_run(self, sources, marker, parse_as_library=True):
        with tempfile.TemporaryDirectory(prefix="penlight-swift-test-") as temporary:
            binary = pathlib.Path(temporary) / "SwiftTests"
            flags = ["-parse-as-library"] if parse_as_library else []
            subprocess.run(
                ["swiftc", *flags, *[str(SOURCES / source) for source in sources], "-o", str(binary)],
                check=True,
                capture_output=True,
                text=True,
            )
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(marker, result.stdout)

    def test_average_color(self):
        self.compile_and_run(
            ["ScreenColor.swift", "tests/ScreenColorTests.swift"], "ScreenColorSampler self-tests passed", parse_as_library=False
        )

    def test_light_engine_effects_and_beat_detector(self):
        self.compile_and_run(
            ["ScreenColor.swift", "PenlightApp/LightEngine.swift", "PenlightApp/BeatDetector.swift", "tests/LightEngineTests.swift"],
            "LightEngine self-tests passed",
        )

    def test_update_version_comparison(self):
        self.compile_and_run(
            ["PenlightApp/UpdateChecker.swift", "tests/UpdateCheckerTests.swift"], "UpdateChecker self-tests passed"
        )

    def test_info_plist_declares_bluetooth_usage(self):
        result = subprocess.run(
            ["plutil", "-extract", "NSBluetoothAlwaysUsageDescription", "raw", str(SOURCES / "PenlightApp" / "Info.plist")],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertTrue(result.stdout.strip())


@unittest.skipUnless(os.path.exists(DOTNET), ".NET SDK not installed")
class WindowsCoreTests(unittest.TestCase):
    def test_protocol_and_color_match_swift_vectors(self):
        env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_NOLOGO="1")
        result = subprocess.run(
            [DOTNET, "run", "--project", str(SOURCES / "windows" / "PenlightCore.Tests")],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PenlightCore self-tests passed", result.stdout)

    def test_windows_app_cross_compiles(self):
        env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_NOLOGO="1")
        result = subprocess.run(
            [DOTNET, "build", str(SOURCES / "windows" / "PenlightSyncWin"), "-c", "Release", "-warnaserror"],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stdout[-3000:])


if __name__ == "__main__":
    unittest.main()
