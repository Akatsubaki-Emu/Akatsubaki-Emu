import Foundation

enum X86_64ALU {
    static let carry: UInt64 = 1 << 0
    static let parity: UInt64 = 1 << 2
    static let auxiliaryCarry: UInt64 = 1 << 4
    static let zero: UInt64 = 1 << 6
    static let sign: UInt64 = 1 << 7
    static let overflow: UInt64 = 1 << 11
    private static let arithmeticMask = carry | parity | auxiliaryCarry | zero | sign | overflow

    struct Result: Equatable {
        let value: UInt64
        let flags: UInt64
    }

    static func add(_ lhs: UInt64, _ rhs: UInt64, width64: Bool, flags: UInt64) -> Result {
        let mask = width64 ? UInt64.max : UInt64(UInt32.max)
        let signBit: UInt64 = width64 ? (UInt64(1) << 63) : (UInt64(1) << 31)
        let a = lhs & mask
        let b = rhs & mask
        let value = (a &+ b) & mask
        let carryOut = width64 ? (a > UInt64.max - b) : (a + b > UInt64(UInt32.max))
        let overflowOut = ((~(a ^ b) & (a ^ value)) & signBit) != 0
        let auxiliary = ((a ^ b ^ value) & 0x10) != 0
        return Result(value: value, flags: makeFlags(value, width64: width64, carry: carryOut,
            auxiliary: auxiliary, overflow: overflowOut, previous: flags))
    }

    static func subtract(_ lhs: UInt64, _ rhs: UInt64, width64: Bool, flags: UInt64) -> Result {
        let mask = width64 ? UInt64.max : UInt64(UInt32.max)
        let signBit: UInt64 = width64 ? (UInt64(1) << 63) : (UInt64(1) << 31)
        let a = lhs & mask
        let b = rhs & mask
        let value = (a &- b) & mask
        let borrow = a < b
        let overflowOut = (((a ^ b) & (a ^ value)) & signBit) != 0
        let auxiliary = ((a ^ b ^ value) & 0x10) != 0
        return Result(value: value, flags: makeFlags(value, width64: width64, carry: borrow,
            auxiliary: auxiliary, overflow: overflowOut, previous: flags))
    }

    static func and(_ lhs: UInt64, _ rhs: UInt64, width64: Bool, flags: UInt64) -> Result {
        let mask = width64 ? UInt64.max : UInt64(UInt32.max)
        let value = (lhs & rhs) & mask
        return Result(value: value, flags: makeFlags(value, width64: width64, carry: false,
            auxiliary: false, overflow: false, previous: flags))
    }

    static func or(_ lhs: UInt64, _ rhs: UInt64, width64: Bool, flags: UInt64) -> Result {
        let mask = width64 ? UInt64.max : UInt64(UInt32.max)
        let value = (lhs | rhs) & mask
        return Result(value: value, flags: makeFlags(value, width64: width64, carry: false,
            auxiliary: false, overflow: false, previous: flags))
    }

    static func xor(_ lhs: UInt64, _ rhs: UInt64, width64: Bool, flags: UInt64) -> Result {
        let mask = width64 ? UInt64.max : UInt64(UInt32.max)
        let value = (lhs ^ rhs) & mask
        return Result(value: value, flags: makeFlags(value, width64: width64, carry: false,
            auxiliary: false, overflow: false, previous: flags))
    }

    static func condition(_ code: UInt8, flags: UInt64) -> Bool? {
        let cf = flags & carry != 0
        let zf = flags & zero != 0
        let sf = flags & sign != 0
        let of = flags & overflow != 0
        switch code & 0x0F {
        case 0x2: return cf
        case 0x3: return !cf
        case 0x4: return zf
        case 0x5: return !zf
        case 0x8: return sf
        case 0x9: return !sf
        case 0xC: return sf != of
        case 0xD: return sf == of
        case 0xE: return zf || (sf != of)
        case 0xF: return !zf && (sf == of)
        default: return nil
        }
    }

    private static func makeFlags(_ value: UInt64, width64: Bool, carry: Bool,
                                  auxiliary: Bool, overflow: Bool, previous: UInt64) -> UInt64 {
        let mask = width64 ? UInt64.max : UInt64(UInt32.max)
        let signBit: UInt64 = width64 ? (UInt64(1) << 63) : (UInt64(1) << 31)
        var result = (previous & ~arithmeticMask) | 0x2
        if carry { result |= self.carry }
        if UInt8(truncatingIfNeeded: value).nonzeroBitCount.isMultiple(of: 2) { result |= parity }
        if auxiliary { result |= auxiliaryCarry }
        if value & mask == 0 { result |= zero }
        if value & signBit != 0 { result |= sign }
        if overflow { result |= self.overflow }
        return result
    }
}
