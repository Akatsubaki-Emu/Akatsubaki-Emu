import Foundation

final class LinuxSyscallDispatcher {
    enum Outcome {
        case returned(UInt64)
        case exited(Int32)
    }

    private let memory: GuestMemory
    private let log: EmulationLog
    private var initialProgramBreak: UInt64 = 0
    private var programBreak: UInt64 = 0
    private var mmapCursor: UInt64 = 0
    private var minimumMmapCursor: UInt64 = 0
    private var stackBase: UInt64 = 0
    private var mappedRanges: [Range<UInt64>] = []
    private var closedStandardDescriptorMask: UInt8 = 0
    private let standardInputCondition = NSCondition()
    private var standardInputBuffer = Data()
    private var standardInputClosed = false
    private var standardInputInterrupted = false
    private static let maximumStandardInputBytes = 65_536

    init(memory: GuestMemory, log: EmulationLog = .shared) {
        self.memory = memory
        self.log = log
    }

    func configure(programBreak: UInt64, stackBase: UInt64) throws {
        let initial = Self.alignUp(programBreak)
        guard initial <= memory.size, stackBase <= memory.size,
              initial <= stackBase, stackBase >= 4096 else {
            throw GuestEngineError.invalidState("The Linux heap/stack layout is outside guest memory.")
        }
        initialProgramBreak = initial
        self.programBreak = initial
        self.stackBase = stackBase
        let (rawCursor, overflow) = initial.addingReportingOverflow(0x10000)
        let minimumCursor = overflow ? UInt64.max : Self.alignUp(rawCursor)
        minimumMmapCursor = minimumCursor
        let preferred = max(minimumCursor, 0x10000000)
        mmapCursor = preferred < stackBase ? preferred : minimumCursor
        mappedRanges.removeAll(keepingCapacity: true)
        closedStandardDescriptorMask = 0
        resetStandardInputState()
    }

    func reset() {
        let heapStart = Self.alignUp(initialProgramBreak)
        let heapEnd = Self.alignUp(programBreak)
        if heapEnd > heapStart {
            _ = memory.unmap(offset: heapStart, length: heapEnd - heapStart)
        }
        for range in mappedRanges {
            _ = memory.unmap(offset: range.lowerBound, length: range.upperBound - range.lowerBound)
        }
        programBreak = initialProgramBreak
        mappedRanges.removeAll(keepingCapacity: true)
        closedStandardDescriptorMask = 0
        resetStandardInputState()
        let (rawCursor, overflow) = initialProgramBreak.addingReportingOverflow(0x10000)
        let minimumCursor = overflow ? UInt64.max : Self.alignUp(rawCursor)
        minimumMmapCursor = minimumCursor
        let preferred = max(minimumCursor, 0x10000000)
        mmapCursor = preferred < stackBase ? preferred : minimumCursor
    }

    private func resetStandardInputState() {
        standardInputCondition.lock()
        standardInputBuffer.removeAll(keepingCapacity: true)
        standardInputClosed = false
        standardInputInterrupted = false
        standardInputCondition.broadcast()
        standardInputCondition.unlock()
    }

    /// Queue bytes for guest file descriptor 0 without allowing unbounded host memory growth.
    @discardableResult
    func enqueueStandardInput(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        standardInputCondition.lock()
        defer { standardInputCondition.unlock() }
        guard !standardInputClosed else { return 0 }
        let remaining = Self.maximumStandardInputBytes - standardInputBuffer.count
        guard data.count <= remaining else { return 0 }
        standardInputBuffer.append(data)
        standardInputCondition.signal()
        return data.count
    }

    /// Deliver EOF after any queued bytes have been consumed.
    func closeStandardInput() {
        standardInputCondition.lock()
        standardInputClosed = true
        standardInputCondition.broadcast()
        standardInputCondition.unlock()
    }

    /// Wake a guest blocked in read(0, ...) when the runtime is stopped.
    func interruptStandardInputRead() {
        standardInputCondition.lock()
        standardInputInterrupted = true
        standardInputCondition.broadcast()
        standardInputCondition.unlock()
    }

    func clearStandardInputInterrupt() {
        standardInputCondition.lock()
        standardInputInterrupted = false
        standardInputCondition.unlock()
    }

    private func readStandardInput(address: UInt64, requested: UInt64) -> UInt64 {
        guard requested <= UInt64(Int.max) else { return errno(22) }
        if requested == 0 { return 0 }
        standardInputCondition.lock()
        while standardInputBuffer.isEmpty && !standardInputClosed && !standardInputInterrupted {
            standardInputCondition.wait()
        }
        if standardInputInterrupted {
            standardInputInterrupted = false
            standardInputCondition.unlock()
            return errno(4)
        }
        guard !standardInputBuffer.isEmpty else {
            standardInputCondition.unlock()
            return 0
        }
        let count = min(Int(requested), standardInputBuffer.count)
        let bytes = Data(standardInputBuffer.prefix(count))
        guard memory.write(bytes, offset: address) else {
            standardInputCondition.unlock()
            return errno(14)
        }
        standardInputBuffer.removeSubrange(0..<count)
        standardInputCondition.unlock()
        return UInt64(count)
    }

    func dispatch(number: UInt64, arguments: [UInt64]) -> Outcome? {
        guard arguments.count >= 6 else { return nil }
        return dispatch(number: number, arg0: arguments[0], arg1: arguments[1],
                        arg2: arguments[2], arg3: arguments[3],
                        arg4: arguments[4], arg5: arguments[5])
    }

    func dispatch(number: UInt64, arg0: UInt64, arg1: UInt64, arg2: UInt64,
                  arg3: UInt64, arg4: UInt64, arg5: UInt64) -> Outcome? {
        switch number {
        case 0:
            guard arg0 == 0, !isStandardDescriptorClosed(arg0) else { return .returned(errno(9)) }
            return .returned(readStandardInput(address: arg1, requested: arg2))
        case 1:
            let descriptor = arg0
            let address = arg1
            let requested = arg2
            guard descriptor == 1 || descriptor == 2 else { return .returned(errno(9)) }
            guard !isStandardDescriptorClosed(descriptor) else { return .returned(errno(9)) }
            if requested == 0 { return .returned(0) }
            guard requested <= 1_048_576, requested <= UInt64(Int.max),
                  let bytes = memory.read(offset: address, length: Int(requested)) else {
                return .returned(errno(14))
            }
            logGuestOutput(bytes, descriptor: descriptor)
            return .returned(requested)
        case 20:
            return .returned(writeVector(descriptor: arg0, vectors: arg1, count: arg2))
        case 3:
            guard arg0 <= 2 else { return .returned(errno(9)) }
            let bit = UInt8(1) << UInt8(arg0)
            guard closedStandardDescriptorMask & bit == 0 else { return .returned(errno(9)) }
            closedStandardDescriptorMask |= bit
            return .returned(0)
        case 9:
            guard arg4 == UInt64.max, arg5 == 0 else { return .returned(errno(22)) }
            return .returned(mapAnonymous(address: arg0, length: arg1, protection: arg2, flags: arg3))
        case 10:
            return .returned(protect(address: arg0, length: arg1, protection: arg2))
        case 11:
            return .returned(unmap(address: arg0, length: arg1))
        case 12:
            return .returned(setBreak(arg0))
        case 28:
            return .returned(validateRange(address: arg0, length: arg1))
        case 39, 186:
            return .returned(1)
        case 63:
            return .returned(writeUname(at: arg0))
        case 96:
            return .returned(writeTimeval(at: arg0, timezone: arg1))
        case 102, 104, 107, 108:
            return .returned(0)
        case 202:
            let operation = arg1 & 0x7F
            return .returned(operation == 1 ? 0 : errno(11))
        case 218:
            return .returned(1)
        case 228:
            return .returned(writeTimespec(clock: arg0, at: arg1))
        case 231, 60:
            return .exited(Int32(arg0 & 0xFF))
        case 273:
            return .returned(0)
        case 318:
            return .returned(getRandom(at: arg0, length: arg1, flags: arg2))
        case 334:
            return .returned(errno(38))
        default:
            return nil
        }
    }


    private func isStandardDescriptorClosed(_ descriptor: UInt64) -> Bool {
        guard descriptor <= 2 else { return false }
        let bit = UInt8(1) << UInt8(descriptor)
        return closedStandardDescriptorMask & bit != 0
    }

    private static let maximumVectorCount: UInt64 = 1024
    private static let maximumVectorBytes: UInt64 = 1_048_576

    /// Implements the bounded stdout/stderr form of Linux writev. Guest file
    /// descriptors are not exposed to the host filesystem by this runtime.
    private func writeVector(descriptor: UInt64, vectors: UInt64, count: UInt64) -> UInt64 {
        guard descriptor == 1 || descriptor == 2 else { return errno(9) }
        guard !isStandardDescriptorClosed(descriptor) else { return errno(9) }
        guard count <= Self.maximumVectorCount else { return errno(22) }
        if count == 0 { return 0 }

        let (tableByteCount, tableOverflow) = count.multipliedReportingOverflow(by: 16)
        guard !tableOverflow, tableByteCount <= UInt64(Int.max) else { return errno(22) }
        guard let vectorTable = memory.read(offset: vectors, length: Int(tableByteCount)) else {
            return errno(14)
        }

        var segments: [(base: UInt64, length: Int)] = []
        segments.reserveCapacity(Int(count))
        var total: UInt64 = 0
        let tableError = vectorTable.withUnsafeBytes { raw -> UInt64? in
            guard raw.count == Int(tableByteCount) else { return errno(14) }
            for index in 0..<count {
                let entryOffset = Int(index) * 16
                let base = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: entryOffset, as: UInt64.self))
                let length = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: entryOffset + 8, as: UInt64.self))
                let (nextTotal, lengthOverflow) = total.addingReportingOverflow(length)
                guard !lengthOverflow, nextTotal <= Self.maximumVectorBytes,
                      length <= UInt64(Int.max) else {
                    return errno(22)
                }
                if length > 0 {
                    guard base <= memory.size, length <= memory.size - base else {
                        return errno(14)
                    }
                    segments.append((base, Int(length)))
                }
                total = nextTotal
            }
            return nil
        }
        if let tableError { return tableError }

        var output = Data(count: Int(total))
        var destinationOffset = 0
        for segment in segments {
            guard memory.read(offset: segment.base, length: segment.length,
                              into: &output, destinationOffset: destinationOffset) else {
                return errno(14)
            }
            destinationOffset += segment.length
        }
        guard destinationOffset == output.count else { return errno(14) }
        logGuestOutput(output, descriptor: descriptor)
        return total
    }

    private func logGuestOutput(_ bytes: Data, descriptor: UInt64) {
        let stream = descriptor == 2 ? "stderr" : "stdout"
        if let text = String(data: bytes, encoding: .utf8), !text.isEmpty {
            var chunk = ""
            var chunkBytes = 0
            for scalar in text.unicodeScalars {
                let scalarByteCount = scalar.utf8.count
                if chunkBytes + scalarByteCount > 4096 {
                    log.write("[guest \(stream)] " + chunk)
                    chunk.removeAll(keepingCapacity: true)
                    chunkBytes = 0
                }
                chunk.unicodeScalars.append(scalar)
                chunkBytes += scalarByteCount
            }
            if !chunk.isEmpty { log.write("[guest \(stream)] " + chunk) }
        } else if !bytes.isEmpty {
            log.write("[guest \(stream)] <\(bytes.count) non-UTF8 bytes>")
        }
    }

    private func setBreak(_ requested: UInt64) -> UInt64 {
        if requested == 0 { return programBreak }
        let stackGuard = stackBase >= 4096 ? stackBase - 4096 : 0
        // mmapCursor is only a placement hint; the stack guard is the heap ceiling.
        let firstMappingIndex = firstMappedRangeEnding(after: initialProgramBreak)
        let firstMapping = firstMappingIndex < mappedRanges.count ? mappedRanges[firstMappingIndex] : nil
        let upperLimit: UInt64
        if let firstMapping {
            upperLimit = firstMapping.lowerBound < initialProgramBreak ? initialProgramBreak : min(firstMapping.lowerBound, stackGuard)
        } else { upperLimit = stackGuard }
        guard requested >= initialProgramBreak, requested <= upperLimit,
              requested <= memory.size else { return programBreak }

        let previousBreak = programBreak
        if requested < previousBreak {
            let shrinkStart = Self.alignUp(requested)
            let shrinkEnd = Self.alignUp(previousBreak)
            if shrinkStart < shrinkEnd && mappedRanges.contains(where: {
                $0.lowerBound < shrinkEnd && $0.upperBound > shrinkStart
            }) {
                return previousBreak
            }
        }

        guard memory.resizeBreak(from: previousBreak, to: requested) == .success else {
            return previousBreak
        }
        programBreak = requested
        if requested > previousBreak {
            mmapCursor = max(mmapCursor, Self.alignUp(requested))
        } else if requested < previousBreak {
            mmapCursor = max(minimumMmapCursor, Self.alignUp(requested))
        }
        return programBreak
    }

    private func mapAnonymous(address requested: UInt64, length: UInt64,
                              protection: UInt64, flags: UInt64) -> UInt64 {
        let mapType = flags & 0x03
        let supportedFlags: UInt64 = 0x03 | 0x10 | 0x20 | 0x100000
        guard length > 0, length <= memory.size, flags & 0x20 != 0,
              flags & ~supportedFlags == 0, protection & ~UInt64(0x7) == 0,
              mapType == 1 || mapType == 2,
              !(flags & 0x10 != 0 && flags & 0x100000 != 0) else { return errno(22) }
        let (rounded, overflow) = length.addingReportingOverflow(4095)
        guard !overflow else { return errno(12) }
        let size = rounded & ~UInt64(4095)
        let limit = stackBase >= 4096 ? stackBase - 4096 : 0
        let fixed = flags & 0x10 != 0
        let noReplace = flags & 0x100000 != 0
        let fixedAddress = fixed || noReplace
        var address: UInt64
        if fixedAddress {
            guard requested & 0xFFF == 0 else { return errno(22) }
            address = requested
        } else {
            let hint = requested == 0 ? mmapCursor : requested & ~UInt64(0xFFF)
            if let hintedAddress = findFreeAddress(startingAt: hint, size: size, limit: limit) {
                address = hintedAddress
            } else if let cursorAddress = findFreeAddress(startingAt: mmapCursor, size: size, limit: limit) {
                address = cursorAddress
            } else {
                return errno(12)
            }
        }
        let (end, endOverflow) = address.addingReportingOverflow(size)
        guard !endOverflow, end <= memory.size else { return errno(12) }
        if !fixedAddress && (address < programBreak || end > limit) { return errno(12) }

        // Allocate the Swift range-index update before the native transaction.
        // Once native pages change, assigning this prepared array is non-allocating.
        let nextMappedRanges = mappedRangesAfterMapping(
            address..<end, replacing: fixed
        )
        let result = memory.mapTransaction(
            offset: address, length: size,
            permissions: guestPermissions(protection),
            replaceExisting: fixed
        )
        switch result {
        case .success:
            break
        case .alreadyMapped:
            return noReplace ? errno(17) : errno(12)
        case .allocationFailed:
            return errno(12)
        case .invalid:
            return errno(22)
        }
        mappedRanges = nextMappedRanges
        if !fixedAddress { mmapCursor = max(mmapCursor, end) }
        return address
    }

    private func mappedRangesAfterMapping(
        _ newRange: Range<UInt64>, replacing: Bool
    ) -> [Range<UInt64>] {
        var result: [Range<UInt64>] = []
        result.reserveCapacity(mappedRanges.count + 1)
        for range in mappedRanges {
            if replacing && range.lowerBound < newRange.upperBound
                && range.upperBound > newRange.lowerBound {
                if range.lowerBound < newRange.lowerBound {
                    result.append(range.lowerBound..<newRange.lowerBound)
                }
                if range.upperBound > newRange.upperBound {
                    result.append(newRange.upperBound..<range.upperBound)
                }
            } else {
                result.append(range)
            }
        }
        var lower = 0
        var upper = result.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if result[middle].lowerBound <= newRange.lowerBound { lower = middle + 1 }
            else { upper = middle }
        }
        result.insert(newRange, at: lower)
        return result
    }

    private func mappedRangesAfterRemoving(_ removed: Range<UInt64>) -> [Range<UInt64>] {
        var result: [Range<UInt64>] = []
        result.reserveCapacity(mappedRanges.count + 1)
        for range in mappedRanges {
            if range.upperBound <= removed.lowerBound || range.lowerBound >= removed.upperBound {
                result.append(range)
                continue
            }
            if range.lowerBound < removed.lowerBound {
                result.append(range.lowerBound..<removed.lowerBound)
            }
            if range.upperBound > removed.upperBound {
                result.append(removed.upperBound..<range.upperBound)
            }
        }
        return result
    }

    private func firstMappedRangeEnding(after address: UInt64) -> Int {
        var lower = 0
        var upper = mappedRanges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if mappedRanges[middle].upperBound <= address { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    private func findFreeAddress(startingAt start: UInt64, size: UInt64, limit: UInt64) -> UInt64? {
        var candidate = Self.alignUp(max(start, programBreak))
        for index in firstMappedRangeEnding(after: candidate)..<mappedRanges.count {
            let range = mappedRanges[index]
            let (candidateEnd, overflow) = candidate.addingReportingOverflow(size)
            if overflow { return nil }
            if range.lowerBound >= candidateEnd { break }
            if candidate < range.upperBound { candidate = Self.alignUp(range.upperBound) }
        }
        while memory.hasMappedPages(offset: candidate, length: size) {
            let (next, nextOverflow) = candidate.addingReportingOverflow(4096)
            guard !nextOverflow else { return nil }
            candidate = Self.alignUp(next)
        }
        let (end, overflow) = candidate.addingReportingOverflow(size)
        guard !overflow, end <= limit, end <= memory.size else { return nil }
        return candidate
    }

    private func unmap(address: UInt64, length: UInt64) -> UInt64 {
        guard address & 0xFFF == 0, length > 0 else { return errno(22) }
        let (rounded, overflow) = length.addingReportingOverflow(4095)
        guard !overflow else { return errno(22) }
        let size = rounded & ~UInt64(4095)
        let (end, endOverflow) = address.addingReportingOverflow(size)
        guard !endOverflow, end <= memory.size else { return errno(22) }

        // Prepare the Swift-side range update before the native unmap commits.
        let nextMappedRanges = mappedRangesAfterRemoving(address..<end)
        guard memory.unmap(offset: address, length: size) else { return errno(22) }
        mappedRanges = nextMappedRanges
        mmapCursor = min(mmapCursor, address)
        return 0
    }

    private func protect(address: UInt64, length: UInt64, protection: UInt64) -> UInt64 {
        guard protection & ~UInt64(0x7) == 0,
              address & 0xFFF == 0, length > 0 else { return errno(22) }
        let (rounded, overflow) = length.addingReportingOverflow(4095)
        guard !overflow else { return errno(22) }
        let size = rounded & ~UInt64(4095)
        guard address <= memory.size, size <= memory.size - address else { return errno(22) }
        // GuestMemory is the authority for mapped pages, including PT_LOAD and stack pages.
        guard memory.protect(offset: address, length: size,
                             permissions: guestPermissions(protection)) else {
            return errno(12)
        }
        return 0
    }

    // Preserve Linux PROT_* bits exactly. Instruction fetch uses the separate
    // execute-access API; data reads must still require PROT_READ.
    private func guestPermissions(_ protection: UInt64) -> UInt8 {
        return UInt8(protection & 0x7)
    }

    private func validateRange(address: UInt64, length: UInt64) -> UInt64 {
        guard address & 0xFFF == 0, length > 0 else { return errno(22) }
        let (roundedLength, roundOverflow) = length.addingReportingOverflow(4095)
        guard !roundOverflow else { return errno(22) }
        let size = roundedLength & ~UInt64(4095)
        let (end, overflow) = address.addingReportingOverflow(size)
        guard !overflow, address <= memory.size, end <= memory.size else { return errno(22) }

        // madvise operates on any mapped guest region, not just the anonymous
        // mmap arena. Check every page so a partially unmapped range returns ENOMEM.
        var cursor = address
        while cursor < end {
            guard memory.hasMappedPages(offset: cursor, length: 4096) else { return errno(12) }
            let (next, nextOverflow) = cursor.addingReportingOverflow(4096)
            guard !nextOverflow else { return errno(22) }
            cursor = next
        }
        return 0
    }

    /// Returns a stable, virtual Linux x86-64 identity without exposing host details.
    /// The Linux x86-64 utsname ABI is six fixed 65-byte, NUL-terminated fields.
    private func writeUname(at address: UInt64) -> UInt64 {
        let fields = ["Linux", "akatsubaki", "6.0.0-akatsubaki", "Kenran Buto", "x86_64", "localdomain"]
        var bytes = [UInt8](repeating: 0, count: 65 * fields.count)
        for (index, field) in fields.enumerated() {
            let encoded = Array(field.utf8.prefix(64))
            let start = index * 65
            bytes.replaceSubrange(start..<(start + encoded.count), with: encoded)
        }
        return memory.write(Data(bytes), offset: address) ? 0 : errno(14)
    }

    private func getRandom(at address: UInt64, length: UInt64, flags: UInt64) -> UInt64 {
        guard flags & ~UInt64(0x7) == 0 else { return errno(22) }
        guard length <= 256 * 1024, length <= UInt64(Int.max) else { return errno(22) }
        if length == 0 { return 0 }
        var generator = SystemRandomNumberGenerator()
        let count = Int(length)
        var data = Data(count: count)
        let generated = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            var offset = 0
            while count - offset >= MemoryLayout<UInt64>.size {
                var word = generator.next().littleEndian
                let copied = withUnsafeBytes(of: &word) { source -> Bool in
                    guard let sourceBase = source.baseAddress else { return false }
                    base.advanced(by: offset).update(from: sourceBase.assumingMemoryBound(to: UInt8.self), count: MemoryLayout<UInt64>.size)
                    return true
                }
                guard copied else { return false }
                offset += MemoryLayout<UInt64>.size
            }
            if offset < count {
                var word = generator.next().littleEndian
                let copied = withUnsafeBytes(of: &word) { source -> Bool in
                    guard let sourceBase = source.baseAddress else { return false }
                    base.advanced(by: offset).update(from: sourceBase.assumingMemoryBound(to: UInt8.self), count: count - offset)
                    return true
                }
                guard copied else { return false }
            }
            return true
        }
        guard generated else { return errno(12) }
        return memory.write(data, offset: address) ? length : errno(14)
    }

    private func writeTimespec(clock: UInt64, at address: UInt64) -> UInt64 {
        let interval: TimeInterval
        switch clock {
        case 0: interval = Date().timeIntervalSince1970
        case 1: interval = ProcessInfo.processInfo.systemUptime
        default: return errno(22)
        }
        let seconds = UInt64(max(0, interval))
        let nanoseconds = min(UInt64(999_999_999), UInt64(max(0, (interval - floor(interval)) * 1_000_000_000)))
        return memory.writeUInt64Pair(seconds, nanoseconds, offset: address) ? 0 : errno(14)
    }

    private func writeTimeval(at address: UInt64, timezone: UInt64) -> UInt64 {
        let interval = Date().timeIntervalSince1970
        let seconds = UInt64(max(0, interval))
        let microseconds = min(UInt64(999_999), UInt64(max(0, (interval - floor(interval)) * 1_000_000)))
        guard memory.writeUInt64Pair(seconds, microseconds, offset: address) else { return errno(14) }
        if timezone != 0 && !memory.zero(offset: timezone, length: 8) { return errno(14) }
        return 0
    }

    private func errno(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: -value)
    }

    private static func alignUp(_ value: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(4095)
        return overflow ? UInt64.max & ~UInt64(4095) : sum & ~UInt64(4095)
    }
}
