import unittest
from pathlib import Path


class GuestConsoleInputTests(unittest.TestCase):
    def test_linux_stdin_queue_is_bounded_and_interruptible(self):
        root = Path(__file__).resolve().parents[2]
        dispatcher = (root / "src/Runtime/LinuxSyscallDispatcher.swift").read_text(encoding="utf-8")
        interpreter = (root / "src/Runtime/X86_64Interpreter.swift").read_text(encoding="utf-8")
        self.assertIn("private let standardInputCondition = NSCondition()", dispatcher)
        self.assertIn("maximumStandardInputBytes = 65_536", dispatcher)
        self.assertIn("standardInputCondition.wait()", dispatcher)
        self.assertIn("return errno(4)", dispatcher)
        self.assertIn("return errno(14)", dispatcher)
        self.assertIn("memory.write(bytes, offset: address)", dispatcher)
        self.assertIn("syscallDispatcher.interruptStandardInputRead()", interpreter)
        self.assertIn("syscallDispatcher.enqueueStandardInput(data)", interpreter)

    def test_guest_input_reaches_runtime_and_console_in_order(self):
        root = Path(__file__).resolve().parents[2]
        machine = (root / "src/Runtime/GuestMachine.swift").read_text(encoding="utf-8")
        runtime = (root / "src/Steam/GameLauncher.swift").read_text(encoding="utf-8")
        console = (root / "iSteam/ConsoleViewController.swift").read_text(encoding="utf-8")
        self.assertIn("func enqueueStandardInput(_ data: Data) -> Int", machine)
        self.assertIn("func sendStandardInput(_ data: Data) -> Int", runtime)
        flush = runtime.index("machine.enqueueStandardInput(queuedInput)")
        ready = runtime.index("self.isGuestReady = true", flush)
        flush_lock = runtime.rindex("self.lock.lock()", 0, flush)
        flush_unlock = runtime.index("self.lock.unlock()", ready)
        self.assertLess(flush_lock, flush)
        self.assertLess(flush, ready)
        self.assertLess(ready, flush_unlock)
        self.assertNotIn("self.lock.unlock()", runtime[flush:ready])

        send_start = runtime.index("func sendStandardInput(_ data: Data) -> Int")
        send_enqueue = runtime.index("machine.enqueueStandardInput(data)", send_start)
        send_lock = runtime.rindex("lock.lock()", 0, send_enqueue)
        send_unlock = runtime.index("lock.unlock()", send_enqueue)
        self.assertLess(send_lock, send_enqueue)
        self.assertLess(send_enqueue, send_unlock)
        self.assertIn("pendingInput", runtime)
        self.assertIn("private let inputField = UITextField()", console)
        self.assertIn("keyboardLayoutGuide.topAnchor", console)
        self.assertIn("submitGuestInput", console)
        self.assertIn("LinuxELFRuntime.shared.sendStandardInput(bytes)", console)

    def test_keyboard_layout_safe_area_property_is_availability_guarded(self):
        root = Path(__file__).resolve().parents[2]
        console = (root / "iSteam/ConsoleViewController.swift").read_text(encoding="utf-8")
        project = (root / "project.yml").read_text(encoding="utf-8")
        self.assertIn('iOS: "16.0"', project)
        self.assertRegex(
            console,
            r"if #available\(iOS 17\.0, \*\) \{\s*"
            r"view\.keyboardLayoutGuide\.usesBottomSafeArea = true\s*\}",
        )


if __name__ == "__main__":
    unittest.main()
