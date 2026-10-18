import CryptoKit
import XCTest

@testable import MyVaultKit

final class CryptoTests: XCTestCase {
    func testPBKDF2KnownVector() throws {
        // PBKDF2-HMAC-SHA256, "password" / "salt", 1 iteration, 32 bytes (widely published test vector).
        let key = try VaultCrypto.deriveKey(password: "password", params: KDFParams(iterations: 1, salt: Data("salt".utf8)))
        let hex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testHeaderUnlockAndWrongPassword() throws {
        let (header, key) = try VaultCrypto.makeHeader(password: "correct horse", iterations: 1000)
        let again = try VaultCrypto.unlock(password: "correct horse", header: header)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, again.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try VaultCrypto.unlock(password: "wrong", header: header)) {
            XCTAssertEqual($0 as? VaultError, .wrongPassword)
        }
    }

    func testPasswordIsNormalised() throws {
        // "é" typed as one character or as e + combining accent must unlock the same vault.
        let (header, _) = try VaultCrypto.makeHeader(password: "caf\u{00E9}", iterations: 1000)
        XCTAssertNoThrow(try VaultCrypto.unlock(password: "cafe\u{0301}", header: header))
    }

    func testSealOpenAndTamper() throws {
        let key = SymmetricKey(size: .bits256)
        let ctx = Data("ctx".utf8)
        let blob = try VaultCrypto.seal(Data("secret".utf8), key: key, context: ctx)
        XCTAssertEqual(try VaultCrypto.open(blob, key: key, context: ctx), Data("secret".utf8))

        var bad = blob
        bad[bad.count - 1] ^= 0x01
        XCTAssertThrowsError(try VaultCrypto.open(bad, key: key, context: ctx))
        XCTAssertThrowsError(try VaultCrypto.open(blob, key: key, context: Data("other".utf8)))
        XCTAssertThrowsError(try VaultCrypto.open(blob, key: SymmetricKey(size: .bits256), context: ctx))
    }

    func testChangePasswordKeepsVaultKey() throws {
        let (header, key) = try VaultCrypto.makeHeader(password: "old", iterations: 1000)
        let updated = try VaultCrypto.changePassword(header: header, oldPassword: "old", newPassword: "new", iterations: 1000)
        let key2 = try VaultCrypto.unlock(password: "new", header: updated)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, key2.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try VaultCrypto.unlock(password: "old", header: updated))
        XCTAssertThrowsError(try VaultCrypto.changePassword(header: header, oldPassword: "nope", newPassword: "x", iterations: 1000))
    }

    func testEmptyPasswordRejected() {
        XCTAssertThrowsError(try VaultCrypto.makeHeader(password: "", iterations: 1000))
    }
}

final class TOTPTests: XCTestCase {
    private let sha1Key = Data("12345678901234567890".utf8)

    func testRFC6238SHA1Vectors() {
        // Appendix B of RFC 6238, 8 digits.
        XCTAssertEqual(TOTP.code(key: sha1Key, counter: 59 / 30, digits: 8, algorithm: .sha1), "94287082")
        XCTAssertEqual(TOTP.code(key: sha1Key, counter: 1_111_111_109 / 30, digits: 8, algorithm: .sha1), "07081804")
        XCTAssertEqual(TOTP.code(key: sha1Key, counter: 2_000_000_000 / 30, digits: 8, algorithm: .sha1), "69279037")
    }

    func testRFC6238SHA256Vector() {
        let key = Data("12345678901234567890123456789012".utf8)
        XCTAssertEqual(TOTP.code(key: key, counter: 59 / 30, digits: 8, algorithm: .sha256), "46119246")
    }

    func testCodeFromBase32Secret() {
        let secret = Base32.encode(sha1Key)
        XCTAssertEqual(secret, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        XCTAssertEqual(TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 59)), "287082")
    }

    func testBase32RoundTripAndInvalid() {
        for len in 1...20 {
            let data = VaultCrypto.randomBytes(len)
            XCTAssertEqual(Base32.decode(Base32.encode(data)), data)
        }
        XCTAssertNil(Base32.decode("not base32 !!"))
        XCTAssertNil(Base32.decode(""))
    }

    func testNormalizedSecretFromURI() {
        XCTAssertEqual(
            TOTP.normalizedSecret(from: "otpauth://totp/Example:alex?secret=jbsw y3dp ehpk3pxp&issuer=Example"),
            "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(TOTP.normalizedSecret(from: " jbsw y3dp ehpk 3pxp "), "JBSWY3DPEHPK3PXP")
        XCTAssertNil(TOTP.normalizedSecret(from: "hello world!"))
    }

    func testSecondsRemaining() {
        XCTAssertEqual(TOTP.secondsRemaining(at: Date(timeIntervalSince1970: 60)), 30)
        XCTAssertEqual(TOTP.secondsRemaining(at: Date(timeIntervalSince1970: 89)), 1)
    }
}

final class StrengthTests: XCTestCase {
    func testWeakPasswords() {
        for pw in ["password", "alex1234", "123456", "abc", "qwerty", "aaaaaaaa"] {
            XCTAssertEqual(StrengthEstimator.evaluate(pw).level, .weak, pw)
        }
    }

    func testStrongRandomPassword() {
        XCTAssertEqual(StrengthEstimator.evaluate("vX9#kQ2$mT7!pL4z").level, .strong)
        XCTAssertEqual(StrengthEstimator.evaluate(PasswordGenerator.generate()).level, .strong)
    }

    func testWordsAndYearsAreCheap() {
        let level = StrengthEstimator.evaluate("Summer2024").level
        XCTAssertTrue(level == .weak || level == .fair, "got \(level)")
    }

    func testLongPhrasesAreNotWeak() {
        // Words glued together, with and without spaces or separators, in Spanish and English.
        for pw in ["micontraseñamuyseguradeldia", "el perro verde come manzanas", "correct-horse-battery-staple", "mi casa es tu casa para siempre"] {
            XCTAssertNotEqual(StrengthEstimator.evaluate(pw).level, .weak, pw)
        }
        XCTAssertEqual(StrengthEstimator.evaluate("aaaaaaaa").level, .weak)
        XCTAssertEqual(StrengthEstimator.evaluate("alex1234").level, .weak)
    }

    func testScoreIsMonotonicWithLength() {
        let a = StrengthEstimator.evaluate("k3Qz9").bits
        let b = StrengthEstimator.evaluate("k3Qz9mW2xT7vB").bits
        XCTAssertLessThan(a, b)
    }

    func testAudit() {
        func login(_ name: String, _ pw: String, totp: String? = nil) -> VaultItem {
            VaultItem(name: name, fields: [ItemField(label: "Password", value: pw, type: .secret)], totpSecret: totp)
        }
        let items = [
            login("A", "alex1234"),
            login("B", "vX9#kQ2$mT7!pL4z", totp: "JBSWY3DPEHPK3PXP"),
            login("C", "Same-Pass-Everywhere-91!"),
            login("D", "Same-Pass-Everywhere-91!"),
        ]
        let report = SecurityAudit.run(items)
        XCTAssertEqual(report.weak, [items[0].id])
        XCTAssertEqual(Set(report.reused), [items[2].id, items[3].id])
        XCTAssertEqual(report.reusedGroups.count, 1)
        XCTAssertFalse(report.withoutTwoFactor.contains(items[1].id))
        XCTAssertLessThan(report.score, 100)
        XCTAssertEqual(SecurityAudit.run([]).score, 100)
    }

    func testGeneratorHonoursOptions() {
        let pw = PasswordGenerator.generate(.init(length: 30, lowercase: true, uppercase: false, digits: true, symbols: false))
        XCTAssertEqual(pw.count, 30)
        XCTAssertTrue(pw.allSatisfy { $0.isLowercase || $0.isNumber })
        XCTAssertTrue(pw.contains { $0.isNumber } && pw.contains { $0.isLowercase })
        XCTAssertNotEqual(PasswordGenerator.generate(), PasswordGenerator.generate())
        XCTAssertEqual(PasswordGenerator.generate(.init(length: 1)).count, 4)
        let noAmb = PasswordGenerator.generate(.init(length: 100, symbols: false, avoidAmbiguous: true))
        XCTAssertFalse(noAmb.contains { "O0oIl1".contains($0) })
    }
}
