import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class RuntimeCapabilityRegistryTests(unittest.TestCase):
    def test_interpreter_is_subset_validated_not_full_abi(self):
        source = (ROOT / "src/Runtime/RuntimeCapabilityRegistry.swift").read_text()
        self.assertIn("case validatedSubset", source)
        self.assertIn("level == .validatedSubset", source)
        self.assertIn("records[.x86Interpreter]", source)
        availability = source.split("var backendAvailability:", 1)[1].split("var diagnostics:", 1)[0]
        self.assertNotIn("linuxSyscallABI", availability)

    def test_linux_launch_uses_registry_snapshot(self):
        source = (ROOT / "src/Steam/GameLauncher.swift").read_text()
        self.assertIn("RuntimeCapabilityRegistry.current.backendAvailability", source)
        self.assertNotIn("RuntimeBackendAvailability(installed: [.x86Interpreter])", source)


if __name__ == "__main__":
    unittest.main()
