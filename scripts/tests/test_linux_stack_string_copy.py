import unittest
from pathlib import Path


class LinuxStackStringCopyTests(unittest.TestCase):
    def test_argument_and_environment_strings_skip_intermediate_byte_arrays(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "src" / "Runtime" / "LinuxProcessStackBuilder.swift").read_text(encoding="utf-8")
        reserve = source.split("func reserveString", 1)[1].split("var environmentPointers", 1)[0]
        write = source.split("func writeString", 1)[1].split("for key in environmentKeys.reversed()", 1)[0]
        self.assertIn("value.utf8.count", reserve)
        self.assertIn("let bytes = value.utf8", write)
        self.assertIn("let offset = writeCursor - vectorStart", write)
        self.assertIn("buffer.replaceSubrange", write)
        reserve_environment = source.split("func reserveEnvironmentEntry", 1)[1].split("var environmentPointers", 1)[0]
        self.assertIn("key.utf8.count", reserve_environment)
        self.assertIn("value.utf8.count", reserve_environment)
        self.assertNotIn('"\\(key)=', reserve_environment)
        self.assertNotIn("Array(value.utf8)", source)
        self.assertNotIn("func pushString", source)


if __name__ == "__main__":
    unittest.main()
