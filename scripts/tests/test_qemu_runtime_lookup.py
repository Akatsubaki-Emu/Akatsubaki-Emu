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


    def test_uefi_code_and_variable_store_templates_are_selected_as_matching_pairs(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        pair_finder = runtime.split("private static func findUEFIFirmwarePair", 1)[1].split(
            "private static func findUEFIVariables", 1
        )[0]
        self.assertIn("var candidatesByDirectory: [String: [String: URL]] = [:]", pair_finder)
        self.assertIn("resolved.deletingLastPathComponent().path", pair_finder)
        self.assertIn("candidatesByDirectory[parent, default: [:]]", pair_finder)
        self.assertIn("let sortedDirectories = candidatesByDirectory.keys.sorted", pair_finder)
        self.assertNotIn("containedRegularFile(named: [codeName]", pair_finder)
        for code, variables in (
            ("OVMF_CODE.fd", "OVMF_VARS.fd"),
            ("OVMF_CODE_4M.fd", "OVMF_VARS_4M.fd"),
            ("edk2-x86_64-code.fd", "edk2-x86_64-vars.fd"),
            ("edk2-x86_64-code.secboot.fd", "edk2-x86_64-vars.fd"),
        ):
            with self.subTest(code=code):
                self.assertIn(code, pair_finder)
                self.assertIn(variables, pair_finder)
        self.assertIn("findUEFIVariables(matching: firmware, in: dataDirectory)", runtime)
        self.assertIn("selectedFirmware.lastPathComponent", runtime)

    def test_uefi_variable_store_path_rejects_symlinks_and_escapes(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        store = runtime.split("private static func makeWritableUEFIVariables", 1)[1].split(
            "func stop()", 1
        )[0]
        self.assertIn("resolvingSymlinksInPath().standardizedFileURL", store)
        self.assertIn("directory.standardizedFileURL.path == resolvedDirectory.path", store)
        self.assertIn('resolvedDirectory.path.hasPrefix(supportRoot.path + "/")', store)
        self.assertIn("destinationOfSymbolicLink(atPath: destination.path)", store)
        self.assertIn("destinationValues?.isRegularFile == true", store)
        self.assertIn("destinationValues?.isDirectory == true", store)

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
        library_check = locate.split("func validatedRegularLibrary", 1)[1].split("// Prefer", 1)[0]
        self.assertIn("dataIsDirectory: ObjCBool = false", locate)
        self.assertIn("dataIsDirectory.boolValue", locate)
        self.assertIn("isDirectory: true", locate)
        self.assertIn("resourceValues(forKeys: [.isRegularFileKey])", library_check)
        self.assertIn("values?.isRegularFile == true", library_check)
        self.assertNotIn("isDirectory", library_check)

    def test_start_path_uses_loadability_preflight_before_native_start(self):
        root = Path(__file__).resolve().parents[2]
        status = (root / "src" / "QEMU" / "QEMURuntimeStatus.swift").read_text(encoding="utf-8")
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        inspect = status.split("static func inspect", 1)[1].split("static func locate", 1)[0]
        locate = status.split("static func locate", 1)[1].split("func validateLoadableLibrary", 1)[0]
        self.assertIn("validateLoadableLibrary(libraryURL", inspect)
        self.assertNotIn("validateLoadableLibrary", locate)
        self.assertIn("return .ready(libraryURL: library, dataDirectory: dataDirectory)", locate)
        self.assertIn("switch QEMURuntimeStatus.inspect()", runtime)
        self.assertNotIn("switch QEMURuntimeStatus.locate()", runtime)


    def test_explicit_firmware_uses_only_its_same_directory_variable_store(self):
        root = Path(__file__).resolve().parents[2]
        runtime = (root / "src" / "QEMU" / "QEMUNativeRuntime.swift").read_text(encoding="utf-8")
        finder = runtime.split("private static func findUEFIVariables", 1)[1].split(
            "private static func makeWritableUEFIVariables", 1
        )[0]
        self.assertIn("resolvedFirmware.path.hasPrefix(rootPrefix)", finder)
        self.assertIn("let firmwareDirectory = resolvedFirmware.deletingLastPathComponent()", finder)
        self.assertIn("firmwareDirectory.appendingPathComponent(variablesName)", finder)
        self.assertIn(
            "resolvedVariables.deletingLastPathComponent().path == firmwareDirectory.path",
            finder,
        )
        self.assertIn("variablesValues?.isRegularFile == true", finder)
        self.assertNotIn("containedRegularFile(named: [variablesName], in: directory)", finder)



if __name__ == "__main__":
    unittest.main()
