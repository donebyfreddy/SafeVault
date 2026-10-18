import Foundation

public enum StrengthLevel: String, Codable, Sendable {
    case weak, fair, good, strong

    public var label: String {
        switch self {
        case .weak: "Weak Password"
        case .fair: "Fair Password"
        case .good: "Good Password"
        case .strong: "Strong Password"
        }
    }
}

public struct PasswordStrength: Equatable, Sendable {
    public var bits: Double
    /// 0...1, for drawing a meter.
    public var score: Double
    public var level: StrengthLevel
}

public enum StrengthEstimator {
    private static let common: Set<String> = [
        "password", "passw0rd", "qwerty", "qwertyuiop", "letmein", "welcome", "admin", "login", "iloveyou",
        "monkey", "dragon", "football", "baseball", "master", "sunshine", "princess", "abc123", "123456",
        "12345678", "123456789", "111111", "000000", "secret", "changeme", "default",
    ]

    /// Rough, offline estimate: words and years are cheap to guess, random characters are not.
    public static func evaluate(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return PasswordStrength(bits: 0, score: 0, level: .weak) }
        let lower = password.lowercased()
        if common.contains(lower) { return PasswordStrength(bits: 5, score: 0.05, level: .weak) }

        var bits = 0.0
        var run = [Character]()
        var kind: Int? = nil  // 0 letters, 1 digits, 2 other

        func classOf(_ c: Character) -> Int { c.isLetter ? 0 : (c.isNumber ? 1 : 2) }

        func flush() {
            guard let kind, !run.isEmpty else { return }
            let s = String(run)
            switch kind {
            case 0:
                let l = s.lowercased()
                if common.contains(l) || s.count < 3 {
                    bits += common.contains(l) ? 4 : Double(s.count) * 4.7
                } else if hasInnerCase(s) {
                    bits += Double(s.count) * 5.7
                } else if looksRandomLetters(l) {
                    bits += Double(s.count) * 4.7
                } else {
                    // One word costs ~16 bits; a long run of letters is several words glued together,
                    // so every extra letter beyond a typical word still adds some entropy.
                    bits += min(Double(s.count) * 4.7, 16 + Double(max(0, s.count - 7)) * 2.2)
                }
            case 1:
                if isSequential(s) || Set(s).count == 1 {
                    bits += 4
                } else if s.count == 4, s.hasPrefix("19") || s.hasPrefix("20") {
                    bits += 7
                } else {
                    bits += Double(s.count) * 3.32
                }
            default:
                bits += Double(s.count) * 5
            }
            run.removeAll()
        }

        for c in password {
            let k = classOf(c)
            if k != kind { flush(); kind = k }
            if k == 2 { bits += 5; continue }  // each symbol counts individually
            run.append(c)
        }
        flush()

        // A tiny password is weak no matter how exotic.
        if password.count < 8 { bits = min(bits, 28) }
        let level: StrengthLevel = bits < 32 ? .weak : bits < 48 ? .fair : bits < 62 ? .good : .strong
        return PasswordStrength(bits: bits, score: min(1, bits / 80), level: level)
    }

    private static func hasInnerCase(_ s: String) -> Bool {
        // "aBcD" style: uppercase after the first character.
        s.dropFirst().contains { $0.isUppercase } && s.contains { $0.isLowercase }
    }

    private static func looksRandomLetters(_ s: String) -> Bool {
        guard s.count >= 6 else { return false }
        let vowels = s.filter { "aeiou".contains($0) }.count
        return Double(vowels) / Double(s.count) < 0.15
    }

    private static func isSequential(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count >= 3 else { return false }
        let up = zip(digits, digits.dropFirst()).allSatisfy { $1 == $0 + 1 }
        let down = zip(digits, digits.dropFirst()).allSatisfy { $1 == $0 - 1 }
        return up || down
    }
}

public struct SecurityReport: Equatable, Sendable {
    public var score: Int
    public var weak: [UUID]
    /// Groups of items that share exactly the same password.
    public var reusedGroups: [[UUID]]
    public var withoutTwoFactor: [UUID]

    public var reused: [UUID] { reusedGroups.flatMap { $0 } }
    public var issueCount: Int { Set(weak + reused + withoutTwoFactor).count }
}

public enum SecurityAudit {
    public static func run(_ items: [VaultItem]) -> SecurityReport {
        let logins = items.filter { !$0.deleted && !$0.archived && $0.kind == .login }
        var weak = [UUID]()
        var byPassword = [String: [UUID]]()
        var no2fa = [UUID]()
        for item in logins {
            if let pw = item.password {
                if StrengthEstimator.evaluate(pw).level == .weak { weak.append(item.id) }
                byPassword[pw, default: []].append(item.id)
            }
            if item.totpSecret == nil, item.backupCodes.isEmpty { no2fa.append(item.id) }
        }
        let groups = byPassword.values.filter { $0.count > 1 }.map { $0 }
        let reusedCount = groups.reduce(0) { $0 + $1.count }
        let penalty = Double(weak.count) + 0.6 * Double(reusedCount) + 0.2 * Double(no2fa.count)
        let score = logins.isEmpty ? 100 : Int((100 * max(0, 1 - penalty / Double(logins.count))).rounded())
        return SecurityReport(score: score, weak: weak, reusedGroups: groups, withoutTwoFactor: no2fa)
    }
}
