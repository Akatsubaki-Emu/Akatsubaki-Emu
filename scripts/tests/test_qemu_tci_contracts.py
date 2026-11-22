#!/usr/bin/env python3
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import patch_utm_qemu_ios


class QEMUTCIContractTests(unittest.TestCase):
    def test_runtime_validator_has_valid_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(SCRIPTS / "validate-qemu-runtime.sh")],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tci_runtime_rejects_the_jit_callback_export(self):
        source = (SCRIPTS / "validate-qemu-runtime.sh").read_text(encoding="utf-8")
        self.assertIn('if [[ "$mode" == "tci" ]] && grep -Eq', source)
        self.assertIn("TCI runtime must not export the StikJIT callback.", source)
        self.assertIn("isteam_qemu_set_jit_callbacks", source)
        self.assertIn("required_symbols+=(isteam_qemu_set_jit_callbacks)", source)

    def test_utm_source_must_keep_tci_in_a_separate_build_family(self):
        valid = (
            'case "$PLATFORM" in\\n'
            '  ios-tci) PLATFORM_FAMILY_NAME="$PLATFORM_FAMILY_PREFIX-TCI" ;;\\n'
            'esac\\n'
        )
        patch_utm_qemu_ios.validate_tci_build_directory(valid)
        with self.assertRaisesRegex(SystemExit, "isolates the iOS TCI build directory"):
            patch_utm_qemu_ios.validate_tci_build_directory(valid.replace("-TCI", ""))

    def test_jit_fallback_builds_arguments_from_effective_tci_configuration(self):
        runtime = (Path(__file__).resolve().parents[2] / "src/QEMU/QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        self.assertIn("var effectiveConfiguration = configuration", runtime)
        self.assertIn("effectiveConfiguration.accelerator = requiresJIT ? .jit : .tcg", runtime)
        self.assertIn("QEMUCommandBuilder(configuration: effectiveConfiguration)", runtime)
        self.assertNotIn("QEMUCommandBuilder(configuration: configuration)", runtime)
        self.assertLess(
            runtime.index("effectiveConfiguration.accelerator = requiresJIT ? .jit : .tcg"),
            runtime.index("QEMUCommandBuilder(configuration: effectiveConfiguration)"),
        )


if __name__ == "__main__":
    unittest.main()
