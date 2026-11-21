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
