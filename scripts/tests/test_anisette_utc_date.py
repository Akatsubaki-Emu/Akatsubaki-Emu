import unittest
from pathlib import Path


class AnisetteUTCDateTests(unittest.TestCase):
    def test_v3_date_uses_utc_when_serialized_with_z_suffix(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "iSteam" / "AnisetteDataHelper.swift").read_text(encoding="utf-8")
        date_block = source.split("// Generate date stuff on client", 1)[1].split("} else {", 1)[0]
        # Foundation's .gmt and an explicitly constructed UTC TimeZone are
        # equivalent. Accept both so this contract tests timezone semantics,
        # not one spelling of the Foundation API.
        self.assertRegex(
            date_block,
            r'formatter\.timeZone\s*=\s*(?:TimeZone\(identifier:\s*"UTC"\)|\.gmt)',
        )
        self.assertIn('formatter.dateFormat = "yyyy-MM-dd\'T\'HH:mm:ss\'Z\'"', date_block)
        self.assertNotIn("formatter.timeZone = TimeZone.current", date_block)


if __name__ == "__main__":
    unittest.main()
