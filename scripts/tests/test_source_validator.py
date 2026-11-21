#!/usr/bin/env python3
"""Prevent silent duplicate keys and lifecycle/source-contract regressions."""
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

    def test_native_bridge_enables_strict_c11_strnlen_and_covers_cleanup_race(self):
        root = Path(__file__).resolve().parents[2]
        bridge = (root / "iSteam" / "QEMUNativeBridge.c").read_text(encoding="utf-8")
        test = (root / "scripts" / "tests" / "test_qemu_native_bridge.c").read_text(encoding="utf-8")
        self.assertIn("#define _POSIX_C_SOURCE 200809L", bridge)
        self.assertIn("g_running = false;", bridge)
        self.assertLess(
            bridge.index("g_qemu_main_loop();"),
            bridge.index("g_running = false;", bridge.index("g_qemu_main_loop();")),
        )
        self.assertLess(
            bridge.index("g_running = false;", bridge.index("g_qemu_main_loop();")),
            bridge.index("if (g_qemu_cleanup) g_qemu_cleanup();"),
        )
        self.assertIn("#include <stdlib.h>", test)
        self.assertIn("fake_qemu_cleanup_started_count", test)
        self.assertIn("fake_qemu_shutdown_count", test)

    def test_host_shared_file_import_and_read_enforce_the_transfer_limit(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "HostDeviceBridge.swift").read_text(encoding="utf-8")
        receive = source.split("func receiveFile", 1)[1].split("func readSharedFile", 1)[0]
        read = source.split("func readSharedFile", 1)[1].split("func writeSharedFile", 1)[0]
        self.assertIn("sourceSize <= maximumInMemoryTransferBytes", receive)
        self.assertIn("copiedSize <= maximumInMemoryTransferBytes", receive)
        self.assertIn("maximumInMemoryTransferBytes + 1", read)
        self.assertIn("handle.read(upToCount:", read)


if __name__ == "__main__":
    unittest.main()
