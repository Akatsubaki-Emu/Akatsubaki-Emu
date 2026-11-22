import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

class SecondaryQEMUDiskTests(unittest.TestCase):
    def read(self, path):
        return (ROOT / path).read_text(encoding="utf-8")

    def test_iso_and_writable_disk_use_separate_ahci_ports(self):
        builder = self.read("src/QEMU/QEMUCommandBuilder.swift")
        self.assertIn("writableDiskImage: URL? = nil", builder)
        self.assertIn("isteam-disk", builder)
        self.assertIn("isteam-cdrom", builder)
        self.assertIn("bus=sata0.0", builder)
        self.assertIn("bus=sata0.1,bootindex=1", builder)
        self.assertIn("isteam-secondary-disk", builder)

    def test_secondary_disk_is_validated_and_security_scoped(self):
        runtime = self.read("src/QEMU/QEMUNativeRuntime.swift")
        self.assertIn("[diskImage, writableDiskImage, selectedFirmware]", runtime)
        self.assertIn("The boot image and writable VM disk must be different files.", runtime)
        self.assertIn("writableDiskImage: writableDiskImage", runtime)

    def test_secondary_disk_flows_through_vm_lifecycle(self):
        engine = self.read("src/Core/VMEngine.swift")
        backend = self.read("src/QEMU/QEMUBackend.swift")
        display = self.read("src/Display/VMDisplayViewController.swift")
        self.assertIn("writableDiskImage: URL? = nil", engine)
        self.assertIn("writableDiskImage: writableDiskImage", backend)
        self.assertIn("engine.start(diskImage: diskImage, writableDiskImage: writableDiskImage)", display)

    def test_creation_and_last_session_restore(self):
        store = self.read("src/QEMU/VirtualDiskImageStore.swift")
        launch = self.read("iSteam/LaunchSetupViewController.swift")
        save_store = self.read("src/Core/VMSaveSlotStore.swift")
        library = self.read("iSteam/LibraryViewController.swift")
        self.assertIn("FileHandle(forWritingTo: url)", store)
        self.assertIn("truncate(atOffset: capacity)", store)
        self.assertIn("Create blank VM disk", launch)
        self.assertIn("writableDiskImageBookmark", save_store)
        self.assertIn("session.writableDiskImageURL", library)

if __name__ == "__main__":
    unittest.main()
