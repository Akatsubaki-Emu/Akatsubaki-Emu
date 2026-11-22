import Foundation

/// Loads ELF64 ET_EXEC images and self-contained ET_DYN static PIE images.
/// PIE support is limited to R_X86_64_RELATIVE relocations; dynamic linking is not implemented.
final class ELF64Loader {
    struct Segment {
        let guestAddress: UInt64
        let fileSize: UInt64
        let memorySize: UInt64
        let flags: UInt32
    }

    struct Image {
        let entryPoint: UInt64
        let machine: UInt16
        let segments: [Segment]
        let loadedByteCount: UInt64
        let programHeaderAddress: UInt64
        let programHeaderEntrySize: UInt16
        let programHeaderCount: UInt16
        let maximumGuestAddress: UInt64
    }

    enum LoadError: LocalizedError {
        case unreadable, invalidMagic, unsupportedClassOrEndian
        case truncatedHeader, invalidProgramHeaderTable, noLoadableSegments
        case invalidSegment, segmentOutsideGuestMemory, unsupportedMachine(UInt16)
        case unsupportedFileType(UInt16), unsupportedDynamicImage, programHeadersNotMapped, fileTooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The ELF image could not be read."
            case .fileTooLarge: return "The ELF image exceeds the 512 MiB inspection limit."
            case .invalidMagic: return "The file is not an ELF image."
            case .unsupportedClassOrEndian: return "Only little-endian ELF64 images are supported."
            case .truncatedHeader: return "The ELF64 header is truncated or invalid."
            case .invalidProgramHeaderTable: return "The ELF program-header table is outside the file."
            case .noLoadableSegments: return "The ELF image contains no loadable segments."
            case .invalidSegment: return "An ELF load segment has invalid file or memory sizes."
            case .segmentOutsideGuestMemory: return "An ELF load segment does not fit in guest memory."
            case .unsupportedMachine(let machine): return "Unsupported ELF machine type: \(machine)."
            case .unsupportedFileType(let type): return "Unsupported ELF file type: \(type). Only ET_EXEC and self-contained static ET_DYN images are supported."
            case .unsupportedDynamicImage: return "Dynamic interpreters, dependencies, TLS and non-relative relocations are not supported."
            case .programHeadersNotMapped: return "The ELF program-header table is not mapped inside a loadable segment."
            }
        }
    }

    func load(_ url: URL, into memory: GuestMemory,
              expectedArchitecture: VMConfiguration.Architecture) throws -> Image {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
        catch { throw LoadError.unreadable }
        guard values.isRegularFile == true, let fileSize = values.fileSize else { throw LoadError.unreadable }
        guard fileSize <= 512 * 1024 * 1024 else { throw LoadError.fileTooLarge }
        let data: Data
        do { data = try Data(contentsOf: url, options: [.mappedIfSafe]) }
        catch { throw LoadError.unreadable }
        guard data.count <= 512 * 1024 * 1024 else { throw LoadError.fileTooLarge }

        guard data.count >= 64, data[0] == 0x7F, data[1] == 0x45,
              data[2] == 0x4C, data[3] == 0x46 else { throw LoadError.invalidMagic }
        guard data[4] == 2, data[5] == 1, data[6] == 1 else { throw LoadError.unsupportedClassOrEndian }

        guard let fileType = u16(data, 16), let machine = u16(data, 18),
              let entry = u64(data, 24), let phoff = u64(data, 32),
              let version = u32(data, 20),
              let ehsize = u16(data, 52), let phentsize = u16(data, 54),
              let phnum = u16(data, 56), version == 1, ehsize >= 64, phentsize >= 56 else {
            throw LoadError.truncatedHeader
        }
        guard fileType == 2 || fileType == 3 else {
            throw LoadError.unsupportedFileType(fileType)
        }
        let loadBias: UInt64 = fileType == 3 ? 0x400000 : 0

        let expectedMachine: UInt16
        switch expectedArchitecture {
        case .x86_64: expectedMachine = 62
        case .arm64: expectedMachine = 183
        case .riscv64: expectedMachine = 243
        }
        guard machine == expectedMachine else { throw LoadError.unsupportedMachine(machine) }

        guard phoff <= UInt64(data.count), phoff <= UInt64(Int.max) else {
            throw LoadError.invalidProgramHeaderTable
        }
        let tableOffset = Int(phoff)
        let entrySize = Int(phentsize)
        let entryCount = Int(phnum)
        let programHeaderTableSize = UInt64(entrySize) * UInt64(entryCount)
        guard entryCount == 0 || entrySize <= (data.count - tableOffset) / entryCount else {
            throw LoadError.invalidProgramHeaderTable
        }

        var segments: [Segment] = []
        var pending: [(Segment, Int)] = []
        var rawLoadSegments: [(virtualAddress: UInt64, fileOffset: UInt64, fileSize: UInt64, memorySize: UInt64)] = []
        var dynamicSegment: (virtualAddress: UInt64, fileOffset: UInt64, fileSize: UInt64, memorySize: UInt64)?
        var total: UInt64 = 0
        var mappedProgramHeaderAddress: UInt64?
        var declaredProgramHeaderAddress: UInt64?
        for index in 0..<entryCount {
            let base = tableOffset + index * entrySize
            guard let type = u32(data, base), let flags = u32(data, base + 4),
                  let fileOffset = u64(data, base + 8), let virtualAddress = u64(data, base + 16),
                  let fileSize = u64(data, base + 32), let memorySize = u64(data, base + 40) else {
                throw LoadError.invalidProgramHeaderTable
            }
            if type == 6 {
                guard fileOffset == phoff,
                      fileOffset <= UInt64(data.count),
                      fileSize >= programHeaderTableSize,
                      fileSize <= UInt64(data.count) - fileOffset,
                      memorySize >= fileSize,
                      declaredProgramHeaderAddress == nil else {
                    throw LoadError.invalidProgramHeaderTable
                }
                let (biasedAddress, biasOverflow) = virtualAddress.addingReportingOverflow(loadBias)
                guard !biasOverflow else { throw LoadError.invalidProgramHeaderTable }
                declaredProgramHeaderAddress = biasedAddress
                continue
            }
            if type == 2 {
                guard fileType == 3, dynamicSegment == nil,
                      fileOffset <= UInt64(data.count),
                      fileSize > 0, fileSize <= UInt64(data.count) - fileOffset,
                      fileSize % 16 == 0, fileSize <= 16 * 1024 * 1024,
                      memorySize >= fileSize else {
                    throw LoadError.unsupportedDynamicImage
                }
                dynamicSegment = (virtualAddress: virtualAddress, fileOffset: fileOffset,
                                  fileSize: fileSize, memorySize: memorySize)
                continue
            }
            if type == 3 || type == 7 {
                throw LoadError.unsupportedDynamicImage
            }
            guard type == 1 else { continue }
            guard memorySize > 0, fileSize <= memorySize, fileOffset <= UInt64(data.count),
                  fileSize <= UInt64(data.count) - fileOffset else { throw LoadError.invalidSegment }
            if phoff >= fileOffset {
                let offsetInSegment = phoff - fileOffset
                if offsetInSegment <= fileSize && programHeaderTableSize <= fileSize - offsetInSegment {
                    guard virtualAddress <= UInt64.max - offsetInSegment else { throw LoadError.invalidSegment }
                    let (virtualMapping, mappingOverflow) = virtualAddress.addingReportingOverflow(offsetInSegment)
                    let (mappedAddress, biasOverflow) = virtualMapping.addingReportingOverflow(loadBias)
                    guard !mappingOverflow, !biasOverflow else { throw LoadError.invalidProgramHeaderTable }
                    if let existing = mappedProgramHeaderAddress, existing != mappedAddress {
                        throw LoadError.invalidProgramHeaderTable
                    }
                    mappedProgramHeaderAddress = mappedAddress
                }
            }
            let (loadAddress, addressOverflow) = virtualAddress.addingReportingOverflow(loadBias)
            guard !addressOverflow, loadAddress <= memory.size, memorySize <= memory.size - loadAddress,
                  fileSize <= UInt64(Int.max), loadAddress <= UInt64(Int.max),
                  total <= UInt64.max - memorySize else {
                throw LoadError.segmentOutsideGuestMemory
            }
            guard let alignment = u64(data, base + 48),
                  alignment <= 1 || (
                    alignment & (alignment - 1) == 0
                    && virtualAddress % alignment == fileOffset % alignment
                    && loadBias % alignment == 0
                  ) else { throw LoadError.invalidSegment }
            rawLoadSegments.append((virtualAddress: virtualAddress, fileOffset: fileOffset,
                                    fileSize: fileSize, memorySize: memorySize))
            let segment = Segment(guestAddress: loadAddress, fileSize: fileSize,
                                  memorySize: memorySize, flags: flags)
            segments.append(segment)
            pending.append((segment, Int(fileOffset)))
            total += memorySize
        }

        guard !segments.isEmpty else { throw LoadError.noLoadableSegments }
        let (loadedEntryPoint, entryOverflow) = entry.addingReportingOverflow(loadBias)
        guard !entryOverflow else { throw LoadError.invalidSegment }
        if let dynamicSegment {
            let dynamicIsMapped = rawLoadSegments.contains { segment in
                dynamicSegment.fileOffset >= segment.fileOffset
                    && dynamicSegment.fileOffset - segment.fileOffset <= segment.fileSize
                    && dynamicSegment.fileSize <= segment.fileSize - (dynamicSegment.fileOffset - segment.fileOffset)
                    && dynamicSegment.virtualAddress >= segment.virtualAddress
                    && dynamicSegment.virtualAddress - segment.virtualAddress
                        == dynamicSegment.fileOffset - segment.fileOffset
                    && dynamicSegment.memorySize <= segment.memorySize
                        - (dynamicSegment.virtualAddress - segment.virtualAddress)
            }
            guard dynamicIsMapped else { throw LoadError.unsupportedDynamicImage }
        }
        let orderedSegments = segments.sorted { $0.guestAddress < $1.guestAddress }
        let phdrAddress: UInt64
        if let declaredProgramHeaderAddress {
            guard mappedProgramHeaderAddress == declaredProgramHeaderAddress else {
                throw LoadError.programHeadersNotMapped
            }
            phdrAddress = declaredProgramHeaderAddress
        } else if let mappedProgramHeaderAddress {
            phdrAddress = mappedProgramHeaderAddress
        } else {
            throw LoadError.programHeadersNotMapped
        }
        guard phdrAddress <= memory.size,
              programHeaderTableSize <= memory.size - phdrAddress,
              orderedSegments.contains(where: {
                  phdrAddress >= $0.guestAddress
                      && phdrAddress - $0.guestAddress <= $0.fileSize
                      && programHeaderTableSize <= $0.fileSize - (phdrAddress - $0.guestAddress)
              }) else {
            throw LoadError.programHeadersNotMapped
        }
        for pair in zip(orderedSegments, orderedSegments.dropFirst()) {
            guard pair.0.memorySize <= UInt64.max - pair.0.guestAddress,
                  pair.0.guestAddress + pair.0.memorySize <= pair.1.guestAddress else {
                throw LoadError.invalidSegment
            }
        }
        // The entry point must land inside a loadable executable segment.
        // Merely being within a writable/data PT_LOAD region is not sufficient.
        guard segments.contains(where: {
            ($0.flags & 0x1) != 0
                && loadedEntryPoint >= $0.guestAddress
                && loadedEntryPoint - $0.guestAddress < $0.fileSize
        }) else { throw LoadError.invalidSegment }

        // Start from a clean address space so bytes from a previously loaded image
        // cannot survive outside the new PT_LOAD ranges. Newly allocated native
        // pages are value-initialized to zero, so clearing the sparse page map is
        // sufficient; walking every untouched BSS page would be redundant.
        memory.clear()
        for (segment, fileOffset) in pending where segment.fileSize > 0 {
            let sourceEnd = fileOffset + Int(segment.fileSize)
            guard memory.write(data, sourceRange: fileOffset..<sourceEnd,
                               offset: segment.guestAddress) else {
                throw LoadError.segmentOutsideGuestMemory
            }
        }
        if let dynamicSegment {
            try applyStaticPIERelocations(
                data: data,
                fileOffset: dynamicSegment.fileOffset,
                fileSize: dynamicSegment.fileSize,
                loadBias: loadBias,
                loadSegments: rawLoadSegments,
                memory: memory
            )
        }
        let maximumGuestAddress = orderedSegments.reduce(UInt64(0)) { max($0, $1.guestAddress + $1.memorySize) }
        return Image(entryPoint: loadedEntryPoint, machine: machine, segments: segments, loadedByteCount: total,
                     programHeaderAddress: phdrAddress, programHeaderEntrySize: phentsize,
                     programHeaderCount: phnum, maximumGuestAddress: maximumGuestAddress)
    }

    private func applyStaticPIERelocations(
        data: Data,
        fileOffset: UInt64,
        fileSize: UInt64,
        loadBias: UInt64,
        loadSegments: [(virtualAddress: UInt64, fileOffset: UInt64, fileSize: UInt64, memorySize: UInt64)],
        memory: GuestMemory
    ) throws {
        guard fileOffset <= UInt64(data.count),
              fileSize <= UInt64(data.count) - fileOffset,
              fileSize > 0, fileSize % 16 == 0,
              fileSize <= 16 * 1024 * 1024 else {
            throw LoadError.unsupportedDynamicImage
        }

        var relaAddress: UInt64?
        var relaSize: UInt64?
        var relaEntrySize: UInt64?
        var foundTerminator = false
        let dynamicEntryCount = Int(fileSize / 16)
        for index in 0..<dynamicEntryCount {
            let offset = Int(fileOffset) + index * 16
            guard let tag = u64(data, offset), let value = u64(data, offset + 8) else {
                throw LoadError.unsupportedDynamicImage
            }
            if tag == 0 {
                foundTerminator = true
                break
            }
            switch tag {
            case 1, 2, 12, 13, 17, 18, 19, 20, 22, 23, 25, 26, 27, 32, 33, 35, 36, 37:
                throw LoadError.unsupportedDynamicImage
            case 7:
                guard relaAddress == nil else { throw LoadError.unsupportedDynamicImage }
                relaAddress = value
            case 8:
                guard relaSize == nil else { throw LoadError.unsupportedDynamicImage }
                relaSize = value
            case 9:
                guard relaEntrySize == nil else { throw LoadError.unsupportedDynamicImage }
                relaEntrySize = value
            default:
                break
            }
        }
        guard foundTerminator else { throw LoadError.unsupportedDynamicImage }
        guard let relaAddress, let relaSize else {
            guard relaAddress == nil, relaSize == nil, relaEntrySize == nil else {
                throw LoadError.unsupportedDynamicImage
            }
            return
        }
        guard relaEntrySize == 24, relaSize % 24 == 0,
              relaSize <= 16 * 1024 * 1024 else {
            throw LoadError.unsupportedDynamicImage
        }
        guard relaSize > 0 else { return }

        let relaFileOffset = loadSegments.compactMap { segment -> UInt64? in
            guard relaAddress >= segment.virtualAddress else { return nil }
            let delta = relaAddress - segment.virtualAddress
            guard delta <= segment.fileSize, relaSize <= segment.fileSize - delta else { return nil }
            let (offset, overflow) = segment.fileOffset.addingReportingOverflow(delta)
            return overflow ? nil : offset
        }.first
        guard let relaFileOffset,
              relaFileOffset <= UInt64(data.count),
              relaSize <= UInt64(data.count) - relaFileOffset else {
            throw LoadError.unsupportedDynamicImage
        }

        let relocationCount = Int(relaSize / 24)
        let relocationsApplied = data.withUnsafeBytes { raw -> Bool in
            guard raw.baseAddress != nil else { return false }
            for index in 0..<relocationCount {
                let offset = Int(relaFileOffset) + index * 24
                let target = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                let information = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self))
                let addendBits = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 16, as: UInt64.self))
                let relocationType = UInt32(truncatingIfNeeded: information)
                let symbolIndex = UInt32(information >> 32)
                guard relocationType == 8, symbolIndex == 0,
                      loadSegments.contains(where: { segment in
                          guard target >= segment.virtualAddress else { return false }
                          let delta = target - segment.virtualAddress
                          return delta <= segment.memorySize && 8 <= segment.memorySize - delta
                      }) else {
                    return false
                }
                let (targetAddress, targetOverflow) = target.addingReportingOverflow(loadBias)
                let (relocatedValue, valueOverflow) = Int64(bitPattern: loadBias)
                    .addingReportingOverflow(Int64(bitPattern: addendBits))
                guard !targetOverflow, !valueOverflow, relocatedValue >= 0,
                      memory.writeUInt64(UInt64(relocatedValue), offset: targetAddress) else {
                    return false
                }
            }
            return true
        }
        guard relocationsApplied else { throw LoadError.unsupportedDynamicImage }
    }

    private func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 2 else { return nil }
        return data.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else { return nil }
        return data.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var value: UInt32 = 0
            return isteam_read_le32(bytes, raw.count, offset, &value) ? value : nil
        }
    }

    private func u64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 8 else { return nil }
        return data.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var value: UInt64 = 0
            return isteam_read_le64(bytes, raw.count, offset, &value) ? value : nil
        }
    }
}
