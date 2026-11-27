import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Steam" / "GameLibraryQuery.swift").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class GameLibraryQueryHotPathTests(unittest.TestCase):
    def test_filter_and_sort_reuse_one_mutable_result_array(self):
        apply = section("    func apply(to source:", "\n}\n\n/// A small facade")
        self.assertIn("var result = source", apply)
        self.assertIn("result.removeAll { game in", apply)
        self.assertIn("result.sort(by: orderedBefore)", apply)
        self.assertNotIn("source.filter", apply)
        self.assertNotIn(".sorted", apply)

    def test_zero_limit_returns_before_filtering(self):
        apply = section("    func apply(to source:", "\n}\n\n/// A small facade")
        self.assertIn("if limit == 0 || source.isEmpty { return [] }", apply)
        self.assertLess(apply.index("if limit == 0"), apply.index("result.removeAll"))

    def test_single_result_uses_linear_best_match(self):
        apply = section("    func apply(to source:", "\n}\n\n/// A small facade")
        self.assertIn("if limit == 1", apply)
        self.assertIn("result.min(by: orderedBefore)", apply)

    def test_multiple_result_limit_trims_in_place(self):
        apply = section("    func apply(to source:", "\n}\n\n/// A small facade")
        self.assertIn("result.removeLast(result.count - limit)", apply)
        self.assertNotIn("Array(result.prefix(limit))", apply)

    def test_all_tags_sorts_the_existing_array(self):
        tags = section("    var allTags:", "    var recentlyPlayed:")
        self.assertIn("tags.sort {", tags)
        self.assertNotIn("tags.sorted", tags)

    def test_recently_played_filters_and_sorts_in_place(self):
        recent = section("    var recentlyPlayed:", "\n    }\n}")
        self.assertIn("var result = games", recent)
        self.assertIn("result.removeAll { $0.lastPlayedAt == nil }", recent)
        self.assertIn("result.sort {", recent)
        self.assertNotIn(".filter", recent)
        self.assertNotIn(".sorted", recent)


if __name__ == "__main__":
    unittest.main()
