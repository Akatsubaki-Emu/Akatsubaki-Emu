import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = (ROOT / "src" / "Performance" / "TranslationCache.swift").read_text(encoding="utf-8")
COMPILER = (ROOT / "src" / "Runtime" / "KenranButoAOTCompiler.swift").read_text(encoding="utf-8")


def section(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


class TranslationCacheHotPathTests(unittest.TestCase):
    def test_cache_directory_url_is_resolved_once_and_not_created_by_property_access(self):
        self.assertIn("private let rootDirectory: URL?", CACHE)
        self.assertNotIn("rootDirectoryOverride", CACHE)
        directory = section(CACHE, "var directory: URL", "func prepare()")
        self.assertNotIn("ensureCacheDirectory", directory)
        self.assertNotIn("cacheDirectory()", directory)

    def test_identity_path_resolution_is_pure(self):
        path = section(CACHE, "func path(for identity:", "func load(")
        self.assertIn("rootDirectory.appendingPathComponent", path)
        self.assertNotIn("ensureCacheDirectory", path)
        self.assertNotIn("cacheDirectory()", path)

    def test_cache_load_does_not_create_missing_directory(self):
        load = section(CACHE, "func load(", "func store(")
        self.assertNotIn("ensureCacheDirectory", load)
        self.assertIn("rootDirectory.resolvingSymlinksInPath()", load)

    def test_store_ensures_directory_once_and_reuses_root_for_pruning(self):
        store = section(CACHE, "func store(", "func invalidate(")
        self.assertIn("let root = try ensureCacheDirectory()", store)
        self.assertIn("pruneCache(keeping: file, in: root)", store)
        prune = section(CACHE, "private func pruneCache(", "private static func digest(")
        self.assertNotIn("ensureCacheDirectory", prune)
        self.assertNotIn("cacheDirectory()", prune)

    def test_read_only_admin_operations_do_not_create_directory(self):
        remove = section(CACHE, "func removeAll()", "func statistics()")
        statistics = section(CACHE, "func statistics()", "private func ensureCacheDirectory()")
        self.assertNotIn("ensureCacheDirectory", remove)
        self.assertNotIn("ensureCacheDirectory", statistics)
        self.assertIn("return Statistics(entryCount: 0, totalBytes: 0)", statistics)

    def test_digest_hex_encoding_avoids_per_byte_string_formatting(self):
        self.assertIn("enum SHA256Hex", CACHE)
        self.assertIn("SHA256Hex.digest", CACHE)
        self.assertIn("SHA256Hex.digest(guestCode)", COMPILER)
        self.assertNotIn("String(format:", CACHE)
        self.assertNotIn("String(format:", COMPILER)

    def test_single_cpu_feature_skips_set_and_sort(self):
        self.assertIn("if cpuFeatures.count < 2", CACHE)
        self.assertIn("Array(Set(cpuFeatures)).sorted()", CACHE)


if __name__ == "__main__":
    unittest.main()
