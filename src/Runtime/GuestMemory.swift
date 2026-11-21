import Foundation

/// Sparse guest memory backed by native C++ pages. Bounds are checked by the
/// native implementation; absent pages read as zero without allocating memory.
final class GuestMemory {
    static let pageSize: UInt64 = 4096
    let size: UInt64
    private let native: OpaquePointer?
    var isAvailable: Bool { native != nil }

    init(size: UInt64) {
        self.size = size
        self.native = isteam_guest_memory_create(size)
    }

    deinit {
        if let native { isteam_guest_memory_destroy(native) }
    }

    func read(offset: UInt64, length: Int) -> Data? {
        guard let native, length >= 0, offset <= size, UInt64(length) <= size - offset else { return nil }
        if length == 0 { return Data() }
        var data = Data(count: length)
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isteam_guest_memory_read(native, offset, base, length)
        }
        return success ? data : nil
    }

    func readByte(offset: UInt64) -> UInt8? {
        guard let native, offset < size else { return nil }
        var value: UInt8 = 0
        let success = withUnsafeMutablePointer(to: &value) { pointer in
            isteam_guest_memory_read(native, offset, pointer, 1)
        }
        return success ? value : nil
    }

    @discardableResult
    func writeByte(_ value: UInt8, offset: UInt64) -> Bool {
        guard let native, offset < size else { return false }
        var byte = value
        return withUnsafeBytes(of: &byte) { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isteam_guest_memory_write(native, offset, base, 1)
        }
    }

    func readPrefix(offset: UInt64, into buffer: inout [UInt8]) -> Int? {
        guard let native, offset <= size else { return nil }
        let count = Int(min(UInt64(buffer.count), size - offset))
        guard count > 0 else { return 0 }
        let success = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isteam_guest_memory_read(native, offset, base, count)
        }
        return success ? count : nil
    }

    func readUInt32(offset: UInt64) -> UInt32? {
        guard let native, offset <= size, 4 <= size - offset else { return nil }
        var value: UInt32 = 0
        let success = withUnsafeMutableBytes(of: &value) { bytes -> Bool in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isteam_guest_memory_read(native, offset, base, 4)
        }
        return success ? UInt32(littleEndian: value) : nil
    }

    func readUInt64(offset: UInt64) -> UInt64? {
        guard let native, offset <= size, 8 <= size - offset else { return nil }
        var value: UInt64 = 0
        let success = withUnsafeMutableBytes(of: &value) { bytes -> Bool in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isteam_guest_memory_read(native, offset, base, 8)
        }
        return success ? UInt64(littleEndian: value) : nil
    }

    @discardableResult
    func writeUInt32(_ value: UInt32, offset: UInt64) -> Bool {
        guard let native, offset <= size, 4 <= size - offset else { return false }
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isteam_guest_memory_write(native, offset, base, 4)
        }
    }

    @discardableResult
    func writeUInt64Pair(_ first: UInt64, _ second: UInt64, offset: UInt64) -> Bool {
        guard let native, offset <= size, 16 <= size - offset else { return false }
        var pair = (first.littleEndian, second.littleEndian)
        return withUnsafeBytes(of: &pair) { bytes in
            guard bytes.count == 16,
                  let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isteam_guest_memory_write(native, offset, base, 16)
        }
    }

    @discardableResult
    func writeUInt64(_ value: UInt64, offset: UInt64) -> Bool {
        guard let native, offset <= size, 8 <= size - offset else { return false }
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isteam_guest_memory_write(native, offset, base, 8)
        }
    }

    @discardableResult
    func write(_ data: Data, sourceRange: Range<Int>, offset: UInt64) -> Bool {
        guard let native, sourceRange.lowerBound >= 0,
              sourceRange.upperBound <= data.count,
              offset <= size,
              UInt64(sourceRange.count) <= size - offset else { return false }
        if sourceRange.isEmpty { return true }
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            let source = base.advanced(by: sourceRange.lowerBound)
                .assumingMemoryBound(to: UInt8.self)
            return isteam_guest_memory_write(native, offset, source, sourceRange.count)
        }
    }

    @discardableResult
    func write(_ data: Data, offset: UInt64) -> Bool {
        guard let native, offset <= size, UInt64(data.count) <= size - offset else { return false }
        if data.isEmpty { return true }
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return isteam_guest_memory_write(native, offset, base, data.count)
        }
    }

    @discardableResult
    func zero(offset: UInt64, length: UInt64) -> Bool {
        guard let native else { return false }
        return isteam_guest_memory_zero(native, offset, length)
    }

    func clear() { if let native { isteam_guest_memory_clear(native) } }
    var allocatedPageCount: Int { native.map { Int(isteam_guest_memory_allocated_pages($0)) } ?? 0 }
}
