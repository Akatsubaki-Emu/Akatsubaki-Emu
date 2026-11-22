import Foundation

enum GuestExecutableFormat: String {
    case windowsPE = "Windows PE"
    case linuxELF = "Linux ELF"
    case unknown = "Unknown"
}

struct GuestProcess {
    let executable: URL
    let workingDirectory: URL
    let format: GuestExecutableFormat
    var arguments: [String] = []

    var commandLine: String {
        ([executable.path] + arguments).joined(separator: " ")
    }
}

final class GuestProcessManager {
    static let shared = GuestProcessManager()
    private init() {}

    func inspect(_ url: URL) -> GuestProcessFormatResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size >= 2,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure("The selected executable is not a readable regular file")
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: min(4096, size))) ?? Data()
        if data.count >= 2 && data[data.startIndex] == 0x4D && data[data.startIndex + 1] == 0x5A {
            do {
                _ = try WindowsPEImage.parse(url: url)
                return .success(.windowsPE)
            } catch {
                return .failure("The file has an MZ header but is not a supported PE32+ AMD64 executable: \(error.localizedDescription)")
            }
        }
        if data.count >= 4 && data[data.startIndex] == 0x7F && data[data.startIndex + 1] == 0x45 && data[data.startIndex + 2] == 0x4C && data[data.startIndex + 3] == 0x46 {
            guard isSupportedELF64X86_64(data, fileSize: size) else {
                return .failure("The file is not a supported ELF64 little-endian x86-64 executable")
            }
            return .success(.linuxELF)
        }
        return .success(.unknown)
    }

    private func isSupportedELF64X86_64(_ data: Data, fileSize: Int) -> Bool {
        guard data.count >= 64, fileSize >= 64 else { return false }

        func u16(_ offset: Int) -> UInt16? {
            guard offset >= 0, offset <= data.count - 2 else { return nil }
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }
        func u64(_ offset: Int) -> UInt64? {
            guard offset >= 0, offset <= data.count - 8 else { return nil }
            return UInt64(u32(offset) ?? 0)
                | (UInt64(u32(offset + 4) ?? 0) << 32)
        }

        guard data[0] == 0x7F, data[1] == 0x45, data[2] == 0x4C, data[3] == 0x46,
              data[4] == 2, data[5] == 1, data[6] == 1,
              let type = u16(16), type == 2 || type == 3,
              let machine = u16(18), machine == 0x3E,
              let version = u32(20), version == 1,
              let programHeaderOffset = u64(32), programHeaderOffset >= 64,
              let headerSize = u16(52), headerSize >= 64,
              let programHeaderEntrySize = u16(54), programHeaderEntrySize >= 56,
              let programHeaderCount = u16(56), programHeaderCount > 0 else {
            return false
        }

        let (tableSize, multiplyOverflow) = UInt64(programHeaderEntrySize)
            .multipliedReportingOverflow(by: UInt64(programHeaderCount))
        let (tableEnd, addOverflow) = programHeaderOffset.addingReportingOverflow(tableSize)
        return !multiplyOverflow && !addOverflow && tableEnd <= UInt64(fileSize)
    }    }
}

enum GuestProcessFormatResult {
    case success(GuestExecutableFormat)
    case failure(String)
}
