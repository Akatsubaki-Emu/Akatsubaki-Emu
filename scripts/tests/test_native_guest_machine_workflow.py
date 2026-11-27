import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "validate-kenran-buto-aot.yml"
BRIDGING_HEADER = ROOT / "scripts" / "tests" / "NativeGuestMachine-Bridging-Header.h"


class NativeGuestMachineWorkflowTests(unittest.TestCase):
    def test_validation_workflow_compiles_and_runs_native_guest_machine_smoke(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        required = (
            "Run native GuestMachine stop and pause/resume smoke",
            "iSteam/NativeGuestMemory.cpp",
            "iSteam/NativeEmulation.c",
            "native-emulation.o",
            "iSteam/KenranButoAOTExecutableMemory.c",
            "scripts/tests/NativeGuestMachine-Bridging-Header.h",
            "scripts/tests/test_native_guest_machine_smoke.swift",
            "hybrid_runtime_smoke.elf",
            "hybrid_stdin_smoke.elf",
            "test-native-guest-machine-smoke",
            "-Xlinker -lc++",
        )
        for value in required:
            with self.subTest(value=value):
                self.assertIn(value, workflow)
        step = workflow.split("Run native GuestMachine stop and pause/resume smoke", 1)[1]
        self.assertNotIn("\n        if:", step.split("\n      - name:", 1)[0])

    def test_bridging_header_exposes_aot_and_native_guest_memory_apis(self):
        header = BRIDGING_HEADER.read_text(encoding="utf-8")
        self.assertIn('include "iSteam/JIT26Protocol.h"', header)
        self.assertIn('include "iSteam/NativeEmulation.h"', header)
        self.assertIn('include "iSteam/NativeGuestMemory.h"', header)


if __name__ == "__main__":
    unittest.main()
