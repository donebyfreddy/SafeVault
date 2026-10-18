import Foundation

public struct GeneratorOptions: Equatable, Sendable {
    public var length: Int
    public var lowercase: Bool
    public var uppercase: Bool
    public var digits: Bool
    public var symbols: Bool
    public var avoidAmbiguous: Bool

    public init(
        length: Int = 20, lowercase: Bool = true, uppercase: Bool = true,
        digits: Bool = true, symbols: Bool = true, avoidAmbiguous: Bool = true
    ) {
        self.length = length
        self.lowercase = lowercase
        self.uppercase = uppercase
        self.digits = digits
        self.symbols = symbols
        self.avoidAmbiguous = avoidAmbiguous
    }
}

public enum PasswordGenerator {
    public static func generate(_ options: GeneratorOptions = .init()) -> String {
        let ambiguous = Set("O0oIl1|")
        func pool(_ chars: String) -> [Character] {
            Array(chars).filter { !(options.avoidAmbiguous && ambiguous.contains($0)) }
        }
        var pools = [[Character]]()
        if options.lowercase { pools.append(pool("abcdefghijklmnopqrstuvwxyz")) }
        if options.uppercase { pools.append(pool("ABCDEFGHIJKLMNOPQRSTUVWXYZ")) }
        if options.digits { pools.append(pool("0123456789")) }
        if options.symbols { pools.append(pool("!@#$%^&*-_=+?")) }
        if pools.isEmpty { pools = [pool("abcdefghijklmnopqrstuvwxyz")] }

        let length = min(max(options.length, max(4, pools.count)), 128)
        let all = pools.flatMap { $0 }
        // One character from every selected class, the rest from the union, then shuffled.
        var chars = pools.map { $0[uniform($0.count)] }
        while chars.count < length { chars.append(all[uniform(all.count)]) }
        for i in stride(from: chars.count - 1, to: 0, by: -1) { chars.swapAt(i, uniform(i + 1)) }
        return String(chars)
    }

    /// Unbiased random integer in 0..<upper using the system generator.
    static func uniform(_ upper: Int) -> Int {
        precondition(upper > 0)
        let limit = UInt32.max - (UInt32.max % UInt32(upper))
        while true {
            let bytes = VaultCrypto.randomBytes(4)
            let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if value < limit { return Int(value % UInt32(upper)) }
        }
    }
}
