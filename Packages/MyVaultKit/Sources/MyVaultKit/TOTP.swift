import CryptoKit
import Foundation

public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func decode(_ string: String) -> Data? {
        let cleaned = string.uppercased().filter { $0 != " " && $0 != "-" && $0 != "=" }
        guard !cleaned.isEmpty else { return nil }
        var buffer = 0
        var bits = 0
        var out = [UInt8]()
        for ch in cleaned {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | idx
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return Data(out)
    }

    public static func encode(_ data: Data) -> String {
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 31])
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }
}

/// RFC 6238 time-based one-time passwords (HMAC-SHA1 by default, 6 digits, 30 s).
public enum TOTP {
    public enum Algorithm: Sendable { case sha1, sha256, sha512 }

    public static func code(
        secret: String, at date: Date = Date(), period: Int = 30, digits: Int = 6, algorithm: Algorithm = .sha1
    ) -> String? {
        guard let key = Base32.decode(secret) else { return nil }
        return code(key: key, counter: UInt64(max(0, date.timeIntervalSince1970)) / UInt64(period), digits: digits, algorithm: algorithm)
    }

    public static func secondsRemaining(at date: Date = Date(), period: Int = 30) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }

    public static func code(key: Data, counter: UInt64, digits: Int, algorithm: Algorithm) -> String {
        var big = counter.bigEndian
        let message = Data(bytes: &big, count: 8)
        let symmetric = SymmetricKey(data: key)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetric))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: symmetric))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let truncated =
            (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        return String(format: "%0\(digits)d", Int(truncated % modulus))
    }

    /// Accepts a bare Base32 secret or an `otpauth://totp/...?secret=...` URI.
    public static func normalizedSecret(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth://"),
           let comps = URLComponents(string: trimmed),
           let secret = comps.queryItems?.first(where: { $0.name.lowercased() == "secret" })?.value {
            return Base32.decode(secret) == nil ? nil : secret.uppercased().replacingOccurrences(of: " ", with: "")
        }
        guard Base32.decode(trimmed) != nil else { return nil }
        return trimmed.uppercased().replacingOccurrences(of: " ", with: "")
    }
}
