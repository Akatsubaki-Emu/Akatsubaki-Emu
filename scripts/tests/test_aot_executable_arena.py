import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ARENA_SOURCE = ROOT / "iSteam" / "AOTExecutableArena.c"
HARNESS = Path(__file__).with_name("test_aot_executable_arena.c")


class AOTExecutableArenaTests(unittest.TestCase):
    def test_allocator_alignment_fragmentation_exact_free_and_concurrency(self):
        compiler = shutil.which("clang") or shutil.which("cc")
        if compiler is None:
            self.skipTest("A C compiler is required for the native arena regression test")
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "aot-arena-test"
            subprocess.run(
                [
                    compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                    "-pthread", str(ARENA_SOURCE), str(HARNESS), "-o", str(binary),
                ],
                check=True, capture_output=True, text=True,
            )
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("Kenran Butō executable arena allocator tests passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
