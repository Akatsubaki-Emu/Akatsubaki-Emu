#!/usr/bin/env python3
"""Regression tests for the UTM QEMU runtime packaging script."""

from pathlib import Path
import re
import shlex
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "package-utm-qemu-runtime.sh"


class QEMURuntimePackagerTests(unittest.TestCase):
    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_bash_syntax_is_valid(self) -> None:
        result = subprocess.run(
            ["bash", "-n", str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_archive_argument_reports_usage(self) -> None:
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage: package-utm-qemu-runtime.sh", result.stderr)

    def test_unknown_runtime_mode_is_rejected_before_archive_lookup(self) -> None:
        result = self.run_script("/missing/UTM.xcarchive", "build/out", "invalid")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Runtime mode must be jit or tci", result.stderr)

    def test_unsafe_output_path_is_rejected_before_archive_lookup(self) -> None:
        result = self.run_script("/missing/UTM.xcarchive", "build/../escape", "jit")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Refusing invalid output directory name", result.stderr)

    def test_parameter_expansions_are_not_escaped(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn(chr(92) + "$" + "{", source)
        self.assertNotIn("$" + chr(92) + "{", source)

    def test_export_matcher_interpolates_the_symbol_argument(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        match = re.search(r"(?ms)^has_export\(\) \{\n(?P<body>.*?)^\}", source)
        self.assertIsNotNone(match, "has_export() function must exist")
        candidate_exports = "00000000 T _qemu_init\n00000000 T _qemu_main_loop\n"
        snippet = (
            f"candidate_exports={shlex.quote(candidate_exports)}\n"
            f"has_export() {{\n{match.group('body')}\n}}\n"
            "has_export qemu_init && has_export qemu_main_loop && "
            "! has_export qemu_cleanup"
        )
        result = subprocess.run(
            ["bash", "-c", snippet],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
