import re
import unittest
from pathlib import Path


class KenranButoAOTDocumentationTests(unittest.TestCase):
    def test_documented_translator_version_matches_source(self):
        root = Path(__file__).resolve().parents[2]
        translator = (root / "src" / "Runtime" / "X86_64AOTTranslator.swift").read_text(encoding="utf-8")
        abi = (root / "docs" / "KENRAN_BUTO_AOT_ABI.md").read_text(encoding="utf-8")
        architecture = (root / "docs" / "HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        match = re.search(r'static let translatorVersion = "(\\d+)"', translator)
        self.assertIsNotNone(match, "translator source must declare a numeric cache version")
        version = match.group(1)
        self.assertIn(f"translator version (currently {version})", abi)
        self.assertIn(f"Translator version {version} emits", architecture)
        self.assertNotIn("Translator version 10 emits", architecture)

    def test_documented_subset_includes_current_byte_and_bit_reversal_operations(self):
        root = Path(__file__).resolve().parents[2]
        abi = (root / "docs" / "KENRAN_BUTO_AOT_ABI.md").read_text(encoding="utf-8")
        architecture = (root / "docs" / "HYBRID_RUNTIME_ARCHITECTURE.md").read_text(encoding="utf-8")
        for document in (abi, architecture):
            self.assertIn("MOV r8", document)
            self.assertIn("BSWAP", document)
            self.assertIn("0F C8", document)


if __name__ == "__main__":
    unittest.main()
