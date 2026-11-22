import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class JITHardwareModelTests(unittest.TestCase):
    def test_stikdebug_txm_model_matrix(self):
        root = Path(__file__).resolve().parents[2]
        compiler = shutil.which("cc") or shutil.which("clang")
        if compiler is None:
            self.skipTest("No C compiler is available for the portable hardware-model test")
        source = r'''#include "JITHardwareModel.h"
int main(void) {
    if (iSteamJITHardwareModelTXMModeForOS("iPad15,7", true, true) != ISTEAM_JIT_PROTOCOL_STIKDEBUG) return 1;
    if (iSteamJITHardwareModelTXMModeForOS("iPad8,11", true, true) != ISTEAM_JIT_PROTOCOL_STANDARD) return 2;
    if (iSteamJITHardwareModelTXMModeForOS("iPad8,12", true, true) != ISTEAM_JIT_PROTOCOL_STANDARD) return 3;
    if (iSteamJITHardwareModelTXMModeForOS("iPhone17,1", true, true) != ISTEAM_JIT_PROTOCOL_STIKDEBUG) return 4;
    if (iSteamJITHardwareModelTXMModeForOS("iPhone14,2", false, true) != ISTEAM_JIT_PROTOCOL_STIKDEBUG) return 5;
    if (iSteamJITHardwareModelTXMModeForOS("iPhone14,1", false, true) != ISTEAM_JIT_PROTOCOL_STANDARD) return 6;
    if (iSteamJITHardwareModelTXMModeForOS("iPad14,5", false, true) != ISTEAM_JIT_PROTOCOL_STIKDEBUG) return 7;
    if (iSteamJITHardwareModelTXMModeForOS("iPad14,4", false, true) != ISTEAM_JIT_PROTOCOL_STANDARD) return 8;
    if (iSteamJITHardwareModelTXMModeForOS("iPad", false, true) != ISTEAM_JIT_PROTOCOL_UNKNOWN) return 9;
    if (iSteamJITHardwareModelTXMModeForOS("Mac14,7", false, true) != ISTEAM_JIT_PROTOCOL_UNKNOWN) return 10;
    if (iSteamJITHardwareModelTXMModeForOS("iPad15,7", false, false) != ISTEAM_JIT_PROTOCOL_STANDARD) return 11;
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="isteam-jit-model-") as directory:
            source_path = Path(directory) / "hardware_model_test.c"
            executable = Path(directory) / "hardware_model_test"
            source_path.write_text(source, encoding="utf-8")
            compiled = subprocess.run(
                [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                 "-I", str(root / "iSteam"), str(source_path), "-o", str(executable)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            executed = subprocess.run([str(executable)], capture_output=True, text=True, check=False)
            self.assertEqual(executed.returncode, 0, f"hardware model case failed: {executed.returncode}")
