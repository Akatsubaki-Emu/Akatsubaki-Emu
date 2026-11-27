import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src" / "Runtime" / "X86_64Interpreter.swift"


class InterpreterStopLockingTests(unittest.TestCase):
    def test_all_stop_flag_reads_use_the_locking_helper(self):
        source = SOURCE.read_text(encoding="utf-8")
        helper = re.search(
            r"private func shouldStopExecution\(\) -> Bool\s*\{(?P<body>.*?)\n    \}",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(helper, "stop-state helper must exist")
        body = helper.group("body")
        self.assertIn("stopLock.lock()", body)
        self.assertIn("defer { stopLock.unlock() }", body)
        self.assertIn("return stopRequested", body)
        self.assertNotRegex(source, r"\bif\s+stopRequested\b")
        self.assertNotRegex(source, r"let\s+\w+\s*=\s*stopRequested\b")
        self.assertGreaterEqual(source.count("shouldStopExecution()"), 3)


    def test_source_validator_tracks_locked_stop_state_helper(self):
        validator = (ROOT / "scripts" / "validate-qemu-source.py").read_text(encoding="utf-8")
        self.assertIn('"if shouldStopExecution() { return .interrupted }"', validator)
        self.assertNotIn('"if stopRequested { return .interrupted }"', validator)

    def test_blocking_syscall_observes_host_stop_before_next_guest_instruction(self):
        source = SOURCE.read_text(encoding="utf-8")
        syscall_start = source.index("} else if second == 0x05 {")
        next_opcode = source.index("} else if second == 0x31 {", syscall_start)
        syscall_block = source[syscall_start:next_opcode]
        dispatch_index = syscall_block.index("syscallDispatcher.dispatch(")
        stop_index = syscall_block.index("if shouldStopExecution() { return .interrupted }")
        self.assertGreater(stop_index, dispatch_index)

    def test_blocking_syscall_pause_retries_same_guest_instruction(self):
        source = SOURCE.read_text(encoding="utf-8")
        syscall_start = source.index("} else if second == 0x05 {")
        next_opcode = source.index("} else if second == 0x31 {", syscall_start)
        syscall_block = source[syscall_start:next_opcode]
        self.assertIn("case .paused:", syscall_block)
        self.assertIn("rip = instructionAddress", syscall_block)
        self.assertIn("if shouldPauseExecution() { return .interrupted }", syscall_block)

    def test_guest_machine_pause_uses_non_destructive_request(self):
        machine_source = (ROOT / "src/Runtime/GuestMachine.swift").read_text(encoding="utf-8")
        pause_start = machine_source.index("    func pause() {")
        stop_start = machine_source.index("    func requestStop()", pause_start)
        pause_body = machine_source[pause_start:stop_start]
        self.assertIn("requestActivePause()", pause_body)
        self.assertNotIn("requestActiveStop()", pause_body)


if __name__ == "__main__":
    unittest.main()
