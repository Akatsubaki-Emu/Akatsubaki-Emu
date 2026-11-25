from __future__ import annotations

import os
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "validate-core-only-ipa.sh"


class CoreOnlyIPAValidatorTests(unittest.TestCase):
    def _write_tool(self, path: Path, contents: str) -> None:
        path.write_text(contents)
        path.chmod(0o755)

    def _run_validator(self, platform: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Payload" / "iSteam.app"
            app.mkdir(parents=True)
            (app / "iSteam").write_bytes(b"fake Mach-O; lipo and otool are stubbed")
            with (app / "Info.plist").open("wb") as handle:
                plistlib.dump({
                    "CFBundleExecutable": "iSteam",
                    "CFBundleIdentifier": "com.xthrx.isteam",
                    "MinimumOSVersion": "16.0",
                    "CFBundleSupportedPlatforms": ["iPhoneOS"],
                }, handle)
            ipa = root / "test.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                for item in app.rglob("*"):
                    archive.write(item, item.relative_to(root))

            tools = root / "bin"
            tools.mkdir()
            self._write_tool(tools / "lipo", "#!/bin/sh\\nexit 0\\n")
            self._write_tool(tools / "plutil", "#!/bin/sh\\nexit 0\\n")
            self._write_tool(tools / "PlistBuddy", """#!/bin/sh
case "$2" in
  *CFBundleExecutable*) echo iSteam ;;
  *CFBundleIdentifier*) echo com.xthrx.isteam ;;
  *MinimumOSVersion*) echo 16.0 ;;
  *CFBundleSupportedPlatforms*) echo iPhoneOS ;;
  *) exit 2 ;;
esac
""")
            self._write_tool(tools / "otool", f"""#!/bin/sh
if [ "$1" = "-l" ]; then
cat <<'EOF'
Load command 1
 cmd LC_BUILD_VERSION
 cmdsize 32
 platform {platform}
 minos 16.0
 sdk 27.1
 ntools 1
EOF
else
  printf '%s:\\\\n\\\\t/usr/lib/libSystem.B.dylib\\\\n' "$2"
fi
""")

            env = os.environ.copy()
            env["PATH"] = f"{tools}:{env.get('PATH', '')}"
            env["PLIST_BUDDY"] = str(tools / "PlistBuddy")
            return subprocess.run(
                ["bash", str(VALIDATOR), str(ipa)],
                env=env, capture_output=True, text=True, check=False,
            )

    def test_accepts_numeric_and_symbolic_ios_device_platforms(self) -> None:
        for platform in ("2", "IOS"):
            with self.subTest(platform=platform):
                result = self._run_validator(platform)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Core-only IPA validation: PASS", result.stdout)

    def test_rejects_ios_simulator_platform(self) -> None:
        result = self._run_validator("7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("platform (IOS/2)", result.stderr)

    def test_rejects_unknown_macho_platform(self) -> None:
        result = self._run_validator("UNKNOWN")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("platform (IOS/2)", result.stderr)


if __name__ == "__main__":
    unittest.main()
