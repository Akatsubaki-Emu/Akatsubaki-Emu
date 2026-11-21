#!/usr/bin/env python3
"""Prevent silent duplicate keys in the repository's source-contract validator."""
import ast
import unittest
from pathlib import Path


class SourceValidatorTests(unittest.TestCase):
    def test_required_source_contracts_have_no_duplicate_dictionary_keys(self):
        source = Path(__file__).resolve().parents[1] / "validate-qemu-source.py"
        tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
        assignment = next(
            (
                node for node in ast.walk(tree)
                if isinstance(node, ast.Assign)
                and any(isinstance(target, ast.Name) and target.id == "required"
                        for target in node.targets)
            ),
            None,
        )
        self.assertIsNotNone(assignment, "required source-contract dictionary was not found")
        self.assertIsInstance(assignment.value, ast.Dict)
        keys = [
            key.value for key in assignment.value.keys
            if isinstance(key, ast.Constant) and isinstance(key.value, str)
        ]
        duplicates = sorted({key for key in keys if keys.count(key) > 1})
        self.assertFalse(duplicates, f"duplicate required source-contract keys: {duplicates}")

        for key, value in zip(assignment.value.keys, assignment.value.values):
            if not isinstance(key, ast.Constant) or not isinstance(key.value, str):
                continue
            if not isinstance(value, ast.List):
                continue
            tokens = [
                item.value for item in value.elts
                if isinstance(item, ast.Constant) and isinstance(item.value, str)
            ]
            duplicate_tokens = sorted({token for token in tokens if tokens.count(token) > 1})
            self.assertFalse(
                duplicate_tokens,
                f"duplicate source-contract tokens for {key.value}: {duplicate_tokens}",
            )

    def test_guest_machine_has_one_serialized_stop_entry_point(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "GuestMachine.swift").read_text(encoding="utf-8")
        self.assertEqual(source.count("func stop()"), 1)
        self.assertIn("requestActiveStop()", source)
        self.assertIn("memory.clear()", source)

    def test_qemu_packager_has_one_complete_candidate_scan(self):
        root = Path(__file__).resolve().parents[2]
        package = (root / "scripts" / "package-utm-qemu-runtime.sh").read_text(encoding="utf-8")
        runtime_validator = (root / "scripts" / "validate-qemu-runtime.sh").read_text(encoding="utf-8")
        bridge = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")

        self.assertEqual(package.count('candidate=""'), 1)
        self.assertEqual(package.count('candidate="$file"'), 1)
        self.assertIn("qemu_system_shutdown_request", package)
        self.assertIn("runtime-library-path.txt", package)
        self.assertIn("qemu_system_shutdown_request", runtime_validator)
        self.assertNotIn("duplicate_string", bridge)


if __name__ == "__main__":
    unittest.main()
