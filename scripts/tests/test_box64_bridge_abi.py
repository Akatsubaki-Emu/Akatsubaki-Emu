import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class Box64BridgeABITests(unittest.TestCase):
    def test_box64_library_entrypoint_abi_environment_and_symbol_selection(self):
        root = Path(__file__).resolve().parents[2]
        compiler = shutil.which("cc") or shutil.which("clang")
        if not compiler:
            self.skipTest("A C compiler is required for the native Box64 bridge ABI test.")
        if sys.platform == "win32":
            self.skipTest("The Box64 bridge uses POSIX dynamic-loader and directory APIs.")

        modes = ("dynamic", "static", "missing")
        for mode in modes:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                executable = Path(temporary) / "box64-bridge-abi-test"
                command = [
                    compiler,
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-D_GNU_SOURCE",
                    "-I",
                    str(root / "iSteam"),
                    str(root / "scripts" / "tests" / "test_box64_bridge_abi.c"),
                    str(root / "iSteam" / "Box64Bridge.c"),
                    "-pthread",
                    "-o",
                    str(executable),
                ]
                if mode == "dynamic":
                    command.append("-rdynamic")
                elif mode == "static":
                    command.append("-DISTEAM_BOX64_STATIC")
                else:
                    command.append("-DBOX64_TEST_NO_LIBRARY_MAIN")
                if sys.platform.startswith("linux"):
                    command.append("-ldl")

                subprocess.run(command, check=True, capture_output=True, text=True)
                result = subprocess.run(
                    [str(executable)], check=True, capture_output=True, text=True
                )
                self.assertIn("Box64 bridge ABI", result.stdout)


if __name__ == "__main__":
    unittest.main()
