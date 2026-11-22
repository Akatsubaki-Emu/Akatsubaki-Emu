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
    private var stackBase: UInt64 = 0
    private var mappedRanges: [Range<UInt64>] = []

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
        let preferred = max(minimumCursor, 0x10000000)
        mmapCursor = preferred < stackBase ? preferred : minimumCursor
        mappedRanges.removeAll(keepingCapacity: true)
    }

    func reset() {
        if programBreak > initialProgramBreak {
            _ = memory.zero(offset: initialProgramBreak, length: programBreak - initialProgramBreak)
        }
        for range in mappedRanges {
            _ = memory.zero(offset: range.lowerBound, length: range.upperBound - range.lowerBound)
        }
        programBreak = initialProgramBreak
        mappedRanges.removeAll(keepingCapacity: true)
        let (rawCursor, overflow) = initialProgramBreak.addingReportingOverflow(0x10000)
        let minimumCursor = overflow ? UInt64.max : Self.alignUp(rawCursor)
        let preferred = max(minimumCursor, 0x10000000)
        mmapCursor = preferred < stackBase ? preferred : minimumCursor
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
            return .returned(arg0 == 0 ? 0 : errno(9))
        case 1:
            let descriptor = arg0
            let address = arg1
            let requested = arg2
            guard descriptor == 1 || descriptor == 2 else { return .returned(errno(9)) }
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
            return .returned(arg0 <= 2 ? 0 : errno(9))
        case 9:
            guard arg4 == UInt64.max, arg5 == 0 else { return .returned(errno(22)) }
            return .returned(mapAnonymous(address: arg0, length: arg1, flags: arg3))
        case 10:
            return .returned(validateRange(address: arg0, length: arg1))
        case 11:
            return .returned(unmap(address: arg0, length: arg1))
        case 12:
            return .returned(setBreak(arg0))
        case 28:
            return .returned(validateRange(address: arg0, length: arg1))
        case 39, 186:
            return .returned(1)
        case 96:
            return .returned(writeTimeval(at: arg0, timezone: arg1))
        case 102, 104, 107, 108:
            return .returned(0)
        case 158:
            return .returned(errno(38))
        case 202:
            let operation = arg1 & 0x7F
            return .returned(operation == 1 ? 0 : errno(11))
        case 218:
            return .returned(1)
        case 228:
            return .returned(writeTimespec(clock: arg0, at: arg1))
        case 231, 60:
            return .exited(Int32(truncatingIfNeeded: arg0))
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


    private static let maximumVectorCount: UInt64 = 1024
    private static let maximumVectorBytes: UInt64 = 1_048_576

    /// Implements the bounded stdout/stderr form of Linux writev. Guest file
    /// descriptors are not exposed to the host filesystem by this runtime.
    private func writeVector(descriptor: UInt64, vectors: UInt64, count: UInt64) -> UInt64 {
        guard descriptor == 1 || descriptor == 2 else { return errno(9) }
        guard count <= Self.maximumVectorCount else { return errno(22) }
        if count == 0 { return 0 }

        var output = Data()
        var total: UInt64 = 0
        for index in 0..<count {
            let (entryOffset, offsetOverflow) = vectors.addingReportingOverflow(index * 16)
            let (lengthOffset, lengthOffsetOverflow) = entryOffset.addingReportingOverflow(8)
            guard !offsetOverflow, !lengthOffsetOverflow,
                  let base = memory.readUInt64(offset: entryOffset),
                  let length = memory.readUInt64(offset: lengthOffset) else {
                return errno(14)
            }
            let (nextTotal, lengthOverflow) = total.addingReportingOverflow(length)
            guard !lengthOverflow, nextTotal <= Self.maximumVectorBytes,
                  length <= UInt64(Int.max) else {
                return errno(22)
            }
            if length == 0 { continue }
            guard let bytes = memory.read(offset: base, length: Int(length)) else {
                return errno(14)
            }
            output.append(bytes)
            total = nextTotal
        }

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
                    log.write("[guest \\(stream)] " + chunk)
                    chunk.removeAll(keepingCapacity: true)
                    chunkBytes = 0
                }
                chunk.unicodeScalars.append(scalar)
                chunkBytes += scalarByteCount
            }
            if !chunk.isEmpty { log.write("[guest \\(stream)] " + chunk) }
        } else if !bytes.isEmpty {
            log.write("[guest \\(stream)] <\\(bytes.count) non-UTF8 bytes>")
        }
    }

    private func setBreak(_ requested: UInt64) -> UInt64 {
        if requested == 0 { return programBreak }
        let firstMapping = mappedRanges.first?.lowerBound ?? mmapCursor
        let upperLimit = min(firstMapping, stackBase >= 4096 ? stackBase - 4096 : 0)
        guard requested >= initialProgramBreak, requested <= upperLimit,
              requested <= memory.size else { return programBreak }
        if requested > programBreak {
            guard memory.zero(offset: programBreak, length: requested - programBreak) else { return programBreak }
        } else if requested < programBreak {
            guard memory.zero(offset: requested, length: programBreak - requested) else { return programBreak }
        }
        programBreak = requested
        return programBreak
    }

    private func mapAnonymous(address requested: UInt64, length: UInt64, flags: UInt64) -> UInt64 {
        let mapType = flags & 0x03
        guard length > 0, length <= memory.size, flags & 0x20 != 0,
              mapType == 1 || mapType == 2 else { return errno(22) }
        let (rounded, overflow) = length.addingReportingOverflow(4095)
        guard !overflow else { return errno(12) }
        let size = rounded & ~UInt64(4095)
        let limit = stackBase >= 4096 ? stackBase - 4096 : 0
        let fixed = flags & 0x10 != 0 || flags & 0x100000 != 0
        let noReplace = flags & 0x100000 != 0
        var address: UInt64
        if fixed {
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
        guard !endOverflow, address >= programBreak, end <= limit, end <= memory.size else {
            return errno(12)
        }
        let firstPotential = firstMappedRangeEnding(after: address)
        let overlaps = firstPotential < mappedRanges.count && mappedRanges[firstPotential].lowerBound < end
        var rangeWasCleared = false
        if overlaps {
            if noReplace { return errno(17) }
            guard fixed, unmap(address: address, length: size) == 0 else { return errno(12) }
            rangeWasCleared = true
        }
        if !rangeWasCleared && !memory.zero(offset: address, length: size) { return errno(12) }
        insertMappedRange(address..<end)
        if !fixed { mmapCursor = max(mmapCursor, end) }
        return address
    }

    private func insertMappedRange(_ newRange: Range<UInt64>) {
        var lower = 0
        var upper = mappedRanges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if mappedRanges[middle].lowerBound <= newRange.lowerBound { lower = middle + 1 }
            else { upper = middle }
        }
        mappedRanges.insert(newRange, at: lower)
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
        let limit = stackBase >= 4096 ? stackBase - 4096 : 0
        guard !endOverflow, address >= programBreak, end <= limit, end <= memory.size else {
            return errno(22)
        }

        var remaining: [Range<UInt64>] = []
        for range in mappedRanges {
            if range.upperBound <= address || range.lowerBound >= end {
                remaining.append(range)
                continue
            }

            let overlapStart = max(range.lowerBound, address)
            let overlapEnd = min(range.upperBound, end)
            guard memory.zero(offset: overlapStart, length: overlapEnd - overlapStart) else {
                return errno(22)
            }
            if range.lowerBound < address {
                remaining.append(range.lowerBound..<address)
            }
            if range.upperBound > end {
                remaining.append(end..<range.upperBound)
            }
        }
        mappedRanges = remaining
        return 0
    }

    private func validateRange(address: UInt64, length: UInt64) -> UInt64 {
        guard address & 0xFFF == 0, length > 0 else { return errno(22) }
        let (end, overflow) = address.addingReportingOverflow(length)
        let limit = stackBase >= 4096 ? stackBase - 4096 : 0
        guard !overflow, address >= initialProgramBreak, end <= limit, end <= memory.size else {
            return errno(22)
        }
        var cursor = address
        if cursor < programBreak {
            cursor = min(end, programBreak)
            if cursor == end { return 0 }
        }
        for index in firstMappedRangeEnding(after: cursor)..<mappedRanges.count {
            let range = mappedRanges[index]
            if range.lowerBound > cursor { return errno(12) }
            cursor = min(end, range.upperBound)
            if cursor == end { return 0 }
        }
        return errno(12)
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
