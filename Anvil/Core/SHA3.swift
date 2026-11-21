import Foundation

/// SHA3-512, which CryptoKit doesn't ship. Needed for ChatGPT's proof-of-work challenge.
nonisolated enum SHA3 {
    private static let rate = 72
    private static let rot: [UInt64] = [
        0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41,
        45, 15, 21, 8, 18, 2, 61, 56, 14,
    ]
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]

    static func hash(_ data: Data) -> Data {
        var state = [UInt64](repeating: 0, count: 25)
        var block: [UInt8] = []
        block.reserveCapacity(rate)
        for byte in data {
            block.append(byte)
            if block.count == rate {
                absorb(&state, block)
                block.removeAll(keepingCapacity: true)
            }
        }
        var padded = block
        padded.append(0x06)
        while padded.count < rate - 1 { padded.append(0) }
        padded.append(0x80)
        absorb(&state, padded)

        var out = Data()
        while out.count < 64 {
            for i in 0..<9 {
                var word = state[i].littleEndian
                withUnsafeBytes(of: &word) { out.append(contentsOf: $0) }
            }
            if out.count < 64 { permute(&state) }
        }
        return out.prefix(64)
    }

    private static func absorb(_ state: inout [UInt64], _ block: [UInt8]) {
        for i in 0..<(rate / 8) {
            var word: UInt64 = 0
            for j in 0..<8 { word |= UInt64(block[i * 8 + j]) << (8 * UInt64(j)) }
            state[i] ^= word
        }
        permute(&state)
    }

    private static func permute(_ a: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        var d = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            for x in 0..<5 { c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] }
            for x in 0..<5 { d[x] = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1) }
            for i in 0..<25 { a[i] ^= d[i % 5] }

            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(a[x + 5 * y], rot[x + 5 * y])
                }
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    a[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
                }
            }
            a[0] ^= roundConstants[round]
        }
    }

    private static func rotl(_ v: UInt64, _ n: UInt64) -> UInt64 {
        n == 0 ? v : (v << n) | (v >> (64 - n))
    }
}
