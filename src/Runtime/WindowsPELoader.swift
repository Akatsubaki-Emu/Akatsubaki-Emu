import Foundation

/// Performs bounded, read-only inspection of a Windows PE image.
/// This does not map sections, resolve imports, or execute code.
final class WindowsPELoader {
    struct Image {
        let url: URL
        let isPE: Bool
        let machine: UInt16
        let subsystem: UInt16?
        let is64Bit: Bool
        let sectionCount: UInt16
        let optionalHeaderSize: UInt16
        let fileSize: UInt64
    }

    enum InspectionError: LocalizedError {
        case unreadableFile, tooSmall, invalidDOSHeader, invalidPEOffset
        case invalidSignature, truncatedCOFFHeader, invalidOptionalHeader
        case unsupportedOptionalHeader

        var errorDescription: String? {
            switch self {
            case .unreadableFile: return "The executable could not be read."
            case .tooSmall: return "The file is too small to contain a Windows PE header."
            case .invalidDOSHeader: return "The file does not have a valid MZ/DOS header."
            case .invalidPEOffset: return "The PE header offset is outside the file or overflows."
            case .invalidSignature: return "The PE signature is missing or invalid."
            case .truncatedCOFFHeader: return "The PE COFF header is truncated."
            case .invalidOptionalHeader: return "The PE optional header is truncated or inconsistent."
            case .unsupportedOptionalHeader: return "The PE optional-header magic is not PE32 or PE32+."
            }
        }
    }

    func load(_ url: URL) throws -> Image {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw InspectionError.unreadableFile
        }

        // Reuse the bounded PE32+ parser used by the translation layer. The
        // previous header-only check accepted x86/ARM PE32 files and malformed
        // section/import tables even though this runtime only targets AMD64.
        let parsed = try WindowsPEImage.parse(data)
        let peOffset = Int(readUInt32LE(data, at: 0x3C) ?? 0)
        let coffOffset = peOffset + 4
        let optionalSize = readUInt16LE(data, at: coffOffset + 16) ?? 0
        let optionalOffset = coffOffset + 20
        let subsystem = readUInt16LE(data, at: optionalOffset + 68)

        return Image(
            url: url,
            isPE: true,
            machine: parsed.machine,
            subsystem: subsystem,
            is64Bit: true,
            sectionCount: UInt16(parsed.sections.count),
            optionalHeaderSize: optionalSize,
            fileSize: UInt64(data.count)
        )
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 2 else {
            return nil
        }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else {
            return nil
        }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
