import Foundation

enum ELFValidator {
    enum ValidationError: LocalizedError {
        case notELF
        case not64Bit
        case notX86_64
        case unsupportedFileType
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notELF: return "The selected file is not an ELF executable."
            case .not64Bit: return "Only 64-bit ELF executables are supported."
            case .notX86_64: return "Only x86-64 ELF executables are currently supported."
            case .unsupportedFileType: return "Only ET_EXEC and self-contained static PIE ELF images are supported; dynamic linking is not implemented."
            case .tooLarge: return "The selected ELF executable exceeds the 512 MiB inspection limit."
            }
        }
    }

    static let maximumFileSize = 512 * 1024 * 1024

    static func validate(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw ValidationError.notELF
        }
        guard fileSize <= Self.maximumFileSize else { throw ValidationError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let data = try handle.read(upToCount: 20) ?? Data()
        guard data.count >= 20 else { throw ValidationError.notELF }

        let bytes = [UInt8](data)
        guard bytes[0] == 0x7F, bytes[1] == 0x45, bytes[2] == 0x4C, bytes[3] == 0x46 else {
            throw ValidationError.notELF
        }
        guard bytes[4] == 2 else { throw ValidationError.not64Bit }

        guard bytes[5] == 1, bytes[6] == 1 else { throw ValidationError.notELF }
        let fileType = UInt16(bytes[16]) | (UInt16(bytes[17]) << 8)
        guard fileType == 2 || fileType == 3 else { throw ValidationError.unsupportedFileType }
        let machine = UInt16(bytes[18]) | (UInt16(bytes[19]) << 8)
        guard machine == 62 else { throw ValidationError.notX86_64 }
    }
}
