import CommonCrypto
import Compression
import XCTest

@testable import MyVaultKit

/// Builds files in the documented Safe database layout so the reader can be tested end to end.
/// (No real Safe file was available; this proves the code follows the layout, not that Safe writes exactly this.)
enum SafeFixture {
    static func make(xml: String, password: String, prf: CCPseudoRandomAlgorithm = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), version: UInt8 = 2, zeroPadded: Bool = false) -> Data {
        let salt1 = VaultCrypto.randomBytes(16), iv1 = VaultCrypto.randomBytes(16), salt2 = VaultCrypto.randomBytes(16)
        let iv2 = VaultCrypto.randomBytes(16), key2 = VaultCrypto.randomBytes(32), check = VaultCrypto.randomBytes(32)
        let key1 = SafeInCloudDatabase.pbkdf2(Array(password.utf8), salt: salt1, rounds: 10_000, length: 32, prf: prf)!

        let inner = prefixed(iv2) + prefixed(key2) + prefixed(check)
        var out = Data([0x0C, 0x35, version])
        out += prefixed(salt1) + prefixed(iv1) + prefixed(salt2) + prefixed(encrypt(inner, key: key1, iv: iv1))
        if zeroPadded {
            // A writer that pads with zeros instead of PKCS#7: strict checks fail, the lenient path must still cope.
            var z = zlib(Data(xml.utf8))
            z += Data(repeating: 0, count: (16 - z.count % 16) % 16 == 0 ? 16 : (16 - z.count % 16))
            out += encryptRaw(z, key: key2, iv: iv2)
        } else {
            out += encrypt(zlib(Data(xml.utf8)), key: key2, iv: iv2)
        }
        return out
    }

    static func encryptRaw(_ data: Data, key: Data, iv: Data) -> Data {
        var out = Data(count: data.count)
        var moved = 0
        let cap = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                k.baseAddress, key.count, v.baseAddress, i.baseAddress, data.count, o.baseAddress, cap, &moved)
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        return out
    }

    static func prefixed(_ d: Data) -> Data { Data([UInt8(d.count)]) + d }

    static func encrypt(_ data: Data, key: Data, iv: Data) -> Data {
        var out = Data(count: data.count + 16)
        var moved = 0
        let cap = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress, i.baseAddress, data.count, o.baseAddress, cap, &moved)
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        return out.prefix(moved)
    }

    static func zlib(_ data: Data) -> Data {
        let size = data.count + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(dst, size, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = (b << 16) | a
        return Data([0x78, 0x9C]) + Data(bytes: dst, count: n) + Data([UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
    }
}

final class SafeDatabaseTests: XCTestCase {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <database>
    <label id="7" name="Finance" type="user"/>
    <card title="Gmail" id="1" time_stamp="1600000000">
      <field name="Login" type="login">alex@example.com</field>
      <field name="Password" type="password">vX9#kQ2$mT7!pL4z</field>
      <field name="Website" type="website">https://mail.google.com</field>
      <notes>Main mailbox</notes>
      <label_id>7</label_id>
    </card>
    </database>
    """

    func testRoundTripReadsItems() throws {
        let file = SafeFixture.make(xml: xml, password: "my safe master")
        XCTAssertTrue(SafeInCloudDatabase.looksLikeDatabase(file))
        let result = try SafeImporter.parse(safeDatabase: file, password: "my safe master")
        XCTAssertEqual(result.format, "Safe database")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].name, "Gmail")
        XCTAssertEqual(result.items[0].password, "vX9#kQ2$mT7!pL4z")
        XCTAssertEqual(result.items[0].tags, ["Finance"])
    }

    func testBigDatabaseWithManyCards() throws {
        let cards = (0..<800).map { """
        <card title="Site \($0)" id="\($0)"><field name="Login" type="login">u\($0)</field><field name="Password" type="password">p\($0)-\(String(repeating: "x", count: 40))</field></card>
        """ }.joined()
        let file = SafeFixture.make(xml: "<database>\(cards)</database>", password: "pw")
        XCTAssertEqual(try SafeImporter.parse(safeDatabase: file, password: "pw").items.count, 800)
    }

    func testUnicodePassword() throws {
        let file = SafeFixture.make(xml: xml, password: "contraseña-ñandú-🔐")
        XCTAssertEqual(try SafeImporter.parse(safeDatabase: file, password: "contraseña-ñandú-🔐").items.count, 1)
    }

    func testSHA256FallbackForNewerFiles() throws {
        let file = SafeFixture.make(xml: xml, password: "pw", prf: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), version: 3)
        XCTAssertEqual(try SafeImporter.parse(safeDatabase: file, password: "pw").items.count, 1)
    }

    func testWrongPasswordIsReportedNotGarbage() {
        let file = SafeFixture.make(xml: xml, password: "right")
        for wrong in ["wrong", "", "Right"] {
            XCTAssertThrowsError(try SafeImporter.parse(safeDatabase: file, password: wrong)) {
                XCTAssertEqual($0 as? VaultError, .wrongPassword, wrong)
            }
        }
    }

    func testDamagedAndForeignFilesDoNotCrash() {
        let file = SafeFixture.make(xml: xml, password: "pw")
        XCTAssertThrowsError(try SafeInCloudDatabase.decrypt(file.prefix(20), password: "pw"))
        XCTAssertThrowsError(try SafeInCloudDatabase.decrypt(Data(), password: "pw"))
        XCTAssertThrowsError(try SafeInCloudDatabase.decrypt(VaultCrypto.randomBytes(500), password: "pw"))
        // Damage in the middle of the compressed content must be rejected (a big file, so the middle is real data).
        let cards = (0..<300).map { "<card title=\"Site \($0)\"><field name=\"Login\" type=\"login\">user\($0)</field><field name=\"Password\" type=\"password\">pw\($0)-\(UUID().uuidString)</field></card>" }.joined()
        let big = SafeFixture.make(xml: "<database>\(cards)</database>", password: "pw")
        var damaged = big
        damaged[damaged.count / 2] ^= 0xFF
        XCTAssertThrowsError(try SafeInCloudDatabase.decrypt(damaged, password: "pw"))
    }

    func testIntactFileIsReportedAsVerified() throws {
        let file = SafeFixture.make(xml: xml, password: "pw")
        XCTAssertTrue(try SafeInCloudDatabase.decryptChecked(file, password: "pw").verified)
        XCTAssertFalse(try SafeImporter.parse(safeDatabase: file, password: "pw").warnings.contains { $0.contains("integrity") })
    }

    func testNonStandardPaddingIsAcceptedButFlagged() throws {
        let file = SafeFixture.make(xml: xml, password: "pw", zeroPadded: true)
        let checked = try SafeInCloudDatabase.decryptChecked(file, password: "pw")
        XCTAssertFalse(checked.verified)
        let result = try SafeImporter.parse(safeDatabase: file, password: "pw")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("integrity") })
    }

    func testTextFilesAreNotMistakenForDatabases() {
        XCTAssertFalse(SafeInCloudDatabase.looksLikeDatabase(Data(xml.utf8)))
        XCTAssertFalse(SafeInCloudDatabase.looksLikeDatabase(Data("name,login,password\nA,b,c\nD,e,f,more,more,more,more,more\n".utf8)))
    }
}
