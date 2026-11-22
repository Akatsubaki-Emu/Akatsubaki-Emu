import unittest
from pathlib import Path


class LinuxStackStringCopyTests(unittest.TestCase):
    def test_argument_and_environment_strings_skip_intermediate_byte_arrays(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxProcessStackBuilder.swift").read_text(encoding="utf-8")
        push = source.split("func pushString", 1)[1].split("var environmentPointers", 1)[0]
        self.assertIn("let bytes = value.utf8", push)
        self.assertIn("buffer.replaceSubrange", push)
        self.assertNotIn("Array(value.utf8)", push)


if __name__ == "__main__":
    unittest.main()
