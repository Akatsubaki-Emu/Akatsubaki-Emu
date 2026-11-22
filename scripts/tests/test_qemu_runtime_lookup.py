import unittest
from pathlib import Path


class QEMURuntimeLookupTests(unittest.TestCase):
    def test_firmware_lookup_rejects_non_regular_files_and_escaping_symlinks(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        resolver = runtime.split("private static func containedRegularFile", 1)[1].split(
            "private static func findUEFIFirmware", 1
        )[0]
        self.assertIn("resolvingSymlinksInPath().standardizedFileURL", resolver)
        self.assertIn("resolved.path.hasPrefix(prefix)", resolver)
        self.assertIn("resourceValues(forKeys: [.isRegularFileKey])", resolver)
        self.assertIn("values?.isRegularFile == true", resolver)
        self.assertNotIn("isDirectory", resolver)


    def test_runtime_library_candidates_must_be_contained_regular_files(self):
        root = Path(__file__).resolve().parents[2]
        status = (root / "src" / "QEMU" / "QEMURuntimeStatus.swift").read_text(encoding="utf-8")
        locate = status.split("static func locate", 1)[1].split(
            "private static func validateLoadableLibrary", 1
        )[0]
        self.assertIn("func validatedRegularLibrary", locate)
        self.assertIn("resolved.path.hasPrefix(bundlePrefix)", locate)
        self.assertIn("resourceValues(forKeys: [.isRegularFileKey])", locate)
        self.assertIn("values?.isRegularFile == true", locate)
        self.assertIn("compactMap(validatedRegularLibrary)", locate)
        self.assertNotIn("isDirectory", locate)

    def test_start_path_uses_location_only_and_native_start_validates_load(self):
        root = Path(__file__).resolve().parents[2]
        status = (root / "src" / "QEMU" / "QEMURuntimeStatus.swift").read_text(encoding="utf-8")
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        inspect = status.split("static func inspect", 1)[1].split("static func locate", 1)[0]
        locate = status.split("static func locate", 1)[1].split("func validateLoadableLibrary", 1)[0]
        self.assertIn("validateLoadableLibrary(libraryURL", inspect)
        self.assertNotIn("validateLoadableLibrary", locate)
        self.assertIn("return .ready(libraryURL: library, dataDirectory: dataDirectory)", locate)
        self.assertIn("switch QEMURuntimeStatus.locate()", runtime)
        self.assertNotIn("switch QEMURuntimeStatus.inspect()", runtime)


if __name__ == "__main__":
    unittest.main()
