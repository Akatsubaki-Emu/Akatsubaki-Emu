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

    static func add8(_ lhs: UInt8, _ rhs: UInt8, flags: UInt64) -> Result {
        let wide = UInt16(lhs) + UInt16(rhs)
        let value = UInt8(truncatingIfNeeded: wide)
        let carryOut = wide > 0xFF
        let overflowOut = ((~(lhs ^ rhs) & (lhs ^ value)) & 0x80) != 0
        let auxiliary = ((lhs ^ rhs ^ value) & 0x10) != 0
        return Result(value: UInt64(value), flags: makeFlags8(value, carry: carryOut,
            auxiliary: auxiliary, overflow: overflowOut, previous: flags))
    }

    static func subtract8(_ lhs: UInt8, _ rhs: UInt8, flags: UInt64) -> Result {
        let value = lhs &- rhs
        let borrow = lhs < rhs
        let overflowOut = (((lhs ^ rhs) & (lhs ^ value)) & 0x80) != 0
        let auxiliary = ((lhs ^ rhs ^ value) & 0x10) != 0
        return Result(value: UInt64(value), flags: makeFlags8(value, carry: borrow,
            auxiliary: auxiliary, overflow: overflowOut, previous: flags))
    }

    static func and8(_ lhs: UInt8, _ rhs: UInt8, flags: UInt64) -> Result {
        let value = lhs & rhs
        return Result(value: UInt64(value), flags: makeFlags8(value, carry: false,
            auxiliary: false, overflow: false, previous: flags))
    }

    static func or8(_ lhs: UInt8, _ rhs: UInt8, flags: UInt64) -> Result {
        let value = lhs | rhs
        return Result(value: UInt64(value), flags: makeFlags8(value, carry: false,
            auxiliary: false, overflow: false, previous: flags))
    }

    static func xor8(_ lhs: UInt8, _ rhs: UInt8, flags: UInt64) -> Result {
        let value = lhs ^ rhs
        return Result(value: UInt64(value), flags: makeFlags8(value, carry: false,
            auxiliary: false, overflow: false, previous: flags))
    }

    static func multiply(_ lhs: UInt64, _ rhs: UInt64, width64: Bool, flags: UInt64) -> Result {
        let value: UInt64
        let overflowOut: Bool
        if width64 {
            let product = Int64(bitPattern: lhs).multipliedFullWidth(by: Int64(bitPattern: rhs))
            value = product.low
            let expectedHigh: Int64 = value & (UInt64(1) << 63) == 0 ? 0 : -1
            overflowOut = product.high != expectedHigh
        } else {
            let left = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: lhs)))
            let right = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: rhs)))
            let product = left * right
            let low = UInt32(truncatingIfNeeded: product)
            value = UInt64(low)
            overflowOut = product != Int64(Int32(bitPattern: low))
        }
        var newFlags = flags & ~(carry | overflow)
        if overflowOut { newFlags |= carry | overflow }
        return Result(value: value, flags: newFlags)
    }

    enum ShiftKind {
        case left
        case logicalRight
        case arithmeticRight
    }

    static func shift(_ value: UInt64, count: UInt8, kind: ShiftKind,
                      width64: Bool, flags: UInt64) -> Result {
        let bitCount = width64 ? 64 : 32
        let mask = width64 ? UInt64.max : UInt64(UInt32.max)
        let signBit = UInt64(1) << (bitCount - 1)
        let masked = value & mask
        let countMask: UInt8 = width64 ? 0x3F : 0x1F
        let amount = Int(count & countMask)
        guard amount != 0 else { return Result(value: masked, flags: flags) }

        let result: UInt64
        let carryOut: Bool
        switch kind {
        case .left:
            carryOut = ((masked >> (bitCount - amount)) & 1) != 0
            result = (masked << amount) & mask
        case .logicalRight:
            carryOut = ((masked >> (amount - 1)) & 1) != 0
            result = masked >> amount
        case .arithmeticRight:
            carryOut = ((masked >> (amount - 1)) & 1) != 0
            if width64 {
                result = UInt64(bitPattern: Int64(bitPattern: masked) >> amount)
            } else {
                let signed = Int32(bitPattern: UInt32(truncatingIfNeeded: masked))
                result = UInt64(UInt32(bitPattern: signed >> amount))
            }
        }

        var updatedFlags = flags & ~(carry | parity | zero | sign)
        if amount == 1 { updatedFlags &= ~overflow }
        if carryOut { updatedFlags |= carry }
        if UInt8(truncatingIfNeeded: result).nonzeroBitCount.isMultiple(of: 2) {
            updatedFlags |= parity
        }
        if result & mask == 0 { updatedFlags |= zero }
        if result & signBit != 0 { updatedFlags |= sign }

        if amount == 1 {
            let overflowOut: Bool
            switch kind {
            case .left: overflowOut = (result & signBit != 0) != carryOut
            case .logicalRight: overflowOut = masked & signBit != 0
            case .arithmeticRight: overflowOut = false
            }
            if overflowOut { updatedFlags |= overflow }
        }
        return Result(value: result, flags: updatedFlags)
    }

    static func condition(_ code: UInt8, flags: UInt64) -> Bool {
        switch code & 0x0F {
        case 0x0: return flags & overflow != 0
        case 0x1: return flags & overflow == 0
        case 0x2: return flags & carry != 0
        case 0x3: return flags & carry == 0
        case 0x4: return flags & zero != 0
        case 0x5: return flags & zero == 0
        case 0x6: return flags & (carry | zero) != 0
        case 0x7: return flags & (carry | zero) == 0
        case 0x8: return flags & sign != 0
        case 0x9: return flags & sign == 0
        case 0xA: return flags & parity != 0
        case 0xB: return flags & parity == 0
        case 0xC: return (flags & sign != 0) != (flags & overflow != 0)
        case 0xD: return (flags & sign != 0) == (flags & overflow != 0)
        case 0xE: return flags & zero != 0 || (flags & sign != 0) != (flags & overflow != 0)
        case 0xF: return flags & zero == 0 && (flags & sign != 0) == (flags & overflow != 0)
        default: return false
        }
    }

    private static func makeFlags8(_ value: UInt8, carry: Bool,
                                    auxiliary: Bool, overflow: Bool, previous: UInt64) -> UInt64 {
        var result = (previous & ~arithmeticMask) | 0x2
        if carry { result |= self.carry }
        if value.nonzeroBitCount.isMultiple(of: 2) { result |= parity }
        if auxiliary { result |= auxiliaryCarry }
        if value == 0 { result |= zero }
        if value & 0x80 != 0 { result |= sign }
        if overflow { result |= self.overflow }
        return result
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
