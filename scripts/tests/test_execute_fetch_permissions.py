import pathlib, unittest
class ExecutableFetchTests(unittest.TestCase):
    def test_wide_fallback_fetches_require_execute_permission(self):
        source=(pathlib.Path(__file__).parents[2]/"src/Runtime/X86_64Interpreter.swift").read_text()
        self.assertIn("prepareInstructionWindow(at: instructionAddress)", source)
        self.assertIn("memory.readPrefix(offset: address, into: &instructionWindow)", source)
        self.assertIn("private func fetchByte()", source)
        memory = (pathlib.Path(__file__).parents[2]/"src/Runtime/GuestMemory.swift").read_text()
        self.assertIn("isteam_guest_memory_read_execute_prefix", memory)
        self.assertNotIn("memory.readUInt32(offset: rip)", source)
        self.assertNotIn("memory.readUInt64(offset: rip)", source)
if __name__ == "__main__": unittest.main()
