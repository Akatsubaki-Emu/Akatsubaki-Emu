import Foundation

/// Supported QEMU disk containers. Detection uses file signatures rather than
/// filename extensions, which can be wrong after a user renames an image.
enum QEMUDiskImageFormat: String {
    case raw
    case qcow2
    case vmdk
    case vhdx
    case vdi
    case vpc

    static func detect(at url: URL) -> QEMUDiskImageFormat {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .raw }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 512), !header.isEmpty else { return .raw }
        if header.count >= 4, header.prefix(4) == Data([0x51, 0x46, 0x49, 0xfb]) { return .qcow2 }
        if header.count >= 4, header.prefix(4) == Data([0x4b, 0x44, 0x4d, 0x56]) { return .vmdk }
        if let prefix = String(data: header.prefix(32), encoding: .ascii),
           prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# Disk DescriptorFile") { return .vmdk }
        if header.count >= 8, String(data: header.prefix(8), encoding: .ascii) == "vhdxfile" { return .vhdx }
        if let signature = String(data: header.prefix(64), encoding: .ascii),
           signature.hasPrefix("<<< Oracle VM VirtualBox Disk Image >>>") { return .vdi }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize, size >= 512 {
            try? handle.seek(toOffset: UInt64(size - 512))
            if let footer = try? handle.read(upToCount: 8),
               String(data: footer, encoding: .ascii) == "conectix" { return .vpc }
        }
        return .raw
    }
}

struct QEMUCommandBuilder {
    let configuration: VMConfiguration

    func arguments(diskImage: URL? = nil, firmware: URL? = nil,
                   firmwareVariables: URL? = nil) -> [String] {
        // -nodefaults disables implicit input devices. VNC keyboard/pointer events
        // therefore need an explicit USB controller, keyboard and tablet for every guest.
        let machine = "q35,usb=on"
        let gpu = configuration.bootWindows ? "VGA" : configuration.gpu.rawValue
        let networkDevice = configuration.bootWindows ? "e1000e" : "virtio-net-pci"
        var args = [
            "-machine", machine, "-nodefaults", "-display", "none",
            "-m", "\(configuration.memoryMB)", "-smp", "\(configuration.cpuCount)",
            "-cpu", "max",
            "-accel", configuration.accelerator == .jit ? "tcg,tb-size=128,split-wx=on" : "tcg",
            // Windows includes generic VGA/AHCI/E1000 drivers; Linux can use VirtIO.
            "-device", gpu,
            "-device", "ich9-ahci,id=sata0",
            "-monitor", "none", "-serial", "none", "-parallel", "none",
            "-rtc", "base=utc,clock=host"
        ]
        let bootFromISO = diskImage.map(Self.isISO9660) ?? false
        args += ["-boot", bootFromISO ? "order=d,menu=on,strict=off" : "order=c,menu=on,strict=off"]
        args += ["-netdev", "user,id=isteam-net0",
                  "-device", "\(networkDevice),netdev=isteam-net0",
                  "-device", "virtio-rng-pci"]
        args += ["-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet"]

        // Expose the built-in QEMU VNC server on loopback only. QEMUVNCClient
        // consumes raw framebuffer rectangles and routes keyboard/pointer events.
        args += ["-vnc", "127.0.0.1:0"]
        if let firmware {
            args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(Self.escapeDriveValue(firmware.path))"]
        }
        if let firmwareVariables {
            args += ["-drive", "if=pflash,format=raw,file=\(Self.escapeDriveValue(firmwareVariables.path))"]
        }
        if let diskImage {
            if bootFromISO {
                // Attach installation/live media through the explicit AHCI
                // controller; -cdrom's implicit IDE device is absent under
                // -nodefaults on a q35 machine.
                args += [
                    "-drive", "if=none,id=isteam-cdrom,media=cdrom,format=raw,file=\(Self.escapeDriveValue(diskImage.path))",
                    "-device", "ide-cd,drive=isteam-cdrom,bus=sata0.1,bootindex=1"
                ]
            } else {
                let format = QEMUDiskImageFormat.detect(at: diskImage).rawValue
                args += [
                    "-drive", "if=none,id=isteam-disk,format=\(format),file=\(Self.escapeDriveValue(diskImage.path))",
                    "-device", "ide-hd,drive=isteam-disk,bus=sata0.0,bootindex=1"
                ]
            }
        }
        return args
    }

    /// QEMU drive options are comma-delimited; double literal commas in file paths.
    private static func escapeDriveValue(_ path: String) -> String {
        path.replacingOccurrences(of: ",", with: ",,")
    }

    private static func isISO9660(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 32_769)
            return try handle.read(upToCount: 5) == Data("CD001".utf8)
        } catch {
            return false
        }
    }
}
