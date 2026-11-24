from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "iSteam" / "AnisetteDataHelper.swift"


class AnisetteDataHelperContractTests(unittest.TestCase):
    def test_v3_fetch_preserves_http_response_for_status_validation(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        v3 = source.split("func fetchAnisetteV3", 1)[1]
        self.assertIn(
            "let (data, response) = try await URLSession.shared.data(for: request)",
            v3,
        )
        self.assertIn(
            "self.extractAnisetteData(data, response as? HTTPURLResponse, v3: true)",
            v3,
        )

    def test_errors_use_a_typed_localized_error(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("private struct AnisetteDataError: LocalizedError", source)
        self.assertNotIn("extension String: LocalizedError", source)


if __name__ == "__main__":
    unittest.main()
