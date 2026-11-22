import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "src" / "Runtime" / "HostDeviceBridge.swift").read_text(encoding="utf-8")


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


class HostDeviceBridgeDirectoryHotPathTests(unittest.TestCase):
    def test_shared_directory_url_is_stored_and_initialized_once(self):
        self.assertIn("let sharedDirectoryURL: URL", SOURCE)
        initializer = section("    private init() {", "    enum BridgeError")
        self.assertIn('appendingPathComponent("GuestShared", isDirectory: true)', initializer)
        self.assertIn("createDirectory(at: root", initializer)

    def test_path_resolution_does_not_create_directory(self):
        resolver = section("    private func sharedFileURL(relativePath: String)", "    private static func machineIdentifier()")
        self.assertNotIn("createDirectory", resolver)

    def test_write_paths_still_create_parent_directories(self):
        receive = section("    func receiveFile(", "    func readSharedFile(")
        write = section("    func writeSharedFile(", "    private func sharedFileURL(")
        self.assertIn("createDirectory(", receive)
        self.assertIn("createDirectory(", write)


if __name__ == "__main__":
    unittest.main()
