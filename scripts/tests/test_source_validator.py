#!/usr/bin/env python3
"""Prevent silent duplicate keys in the repository's source-contract validator."""
import ast
import unittest
from pathlib import Path


class SourceValidatorTests(unittest.TestCase):
    def test_required_source_contracts_have_no_duplicate_dictionary_keys(self):
        source = Path(__file__).resolve().parents[1] / "validate-qemu-source.py"
        tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Dict):
                continue
            keys = [
                key.value for key in node.keys
                if isinstance(key, ast.Constant) and isinstance(key.value, str)
            ]
            self.assertEqual(len(keys), len(set(keys)), "duplicate literal key in source validator")


if __name__ == "__main__":
    unittest.main()
