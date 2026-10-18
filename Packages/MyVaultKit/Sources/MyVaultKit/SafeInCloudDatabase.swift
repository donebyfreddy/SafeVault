import CommonCrypto
import Compression
import Foundation

/// Reads the encrypted database file that Safe (SafeInCloud) keeps in your cloud, usually `SafeInCloud.db`.
///
/// Layout, as implemented by the open-source decrypter github.com/evilsocket/SafeInCloud (GPLv3, used here only as a
/// format description; this file is an independent implementation):
///
///     magic (2 bytes) · version (1) · salt1 (len+bytes) · iv1 (len+bytes) · salt2 (len+bytes) ·
///     block (len+bytes, AES-CBC under PBKDF2(password, salt1, 10 000 rounds)) → { iv2 · key2 · check } ·
///     rest of file: AES-CBC under key2/iv2 → zlib stream → the same XML that Safe's "export to XML" produces.
///
/// The format could not be checked against a real database file, so a wrong password and an unsupported format
/// both end as errors, never as garbage items. Nothing is ever written back to the original file.
public enum SafeInCloudDatabase {
    /// True when the data is binary rather than XML or CSV text, so it is probably a Safe database.
    public static func looksLikeDatabase(_ data: Data) -> Bool {
        guard data.count > 48 else { return false }
        let head = data.prefix(64)
        return head.contains { $0 == 0 || ($0 < 9) } || String(data: head, encoding: .utf8) == nil
    }

    /// Returns the decrypted XML. Throws `VaultError.wrongPassword` when nothing decrypts to a valid zlib stream.
    public static func decrypt(_ file: Data, password: String) throws -> Data {
        try decryptChecked(file, password: password).xml
    }

    /// `verified` is true when the padding and the zlib checksum both matched, so damage would have been caught.
    public static func decryptChecked(_ file: Data, password: String) throws -> (xml: Data, verified: Bool) {
        var reader = Reader(file)
        _ = try reader.bytes(2)                // magic
        let version = try reader.byte()
        guard version <= 20 else { throw VaultError.unsupportedVersion(Int(version)) }
        let salt1 = try reader.prefixed()
        let iv1 = try reader.prefixed()
        _ = try reader.prefixed()              // salt2: read by the original, unused for the data key
        let block = try reader.prefixed()
        var rest = reader.rest
        rest = rest.prefix(rest.count - rest.count % 16)
        guard iv1.count == 16, !block.isEmpty, block.count % 16 == 0, !rest.isEmpty else { throw VaultError.corrupted }

        // Older databases use PBKDF2-HMAC-SHA1; SHA-256 is tried as a fallback for newer ones.
        for prf in [CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)] {
            guard let key1 = pbkdf2(Array(password.utf8), salt: salt1, rounds: 10_000, length: 32, prf: prf),
                  let inner = aesCBCDecrypt(block, key: key1, iv: iv1) else { continue }
            var innerReader = Reader(inner)
            guard let iv2 = try? innerReader.prefixed(), let key2 = try? innerReader.prefixed(),
                  iv2.count == 16, [16, 24, 32].contains(key2.count),
                  let compressed = aesCBCDecrypt(rest, key: key2, iv: iv2) else { continue }
            // Strict: PKCS#7 padding plus the adler32 trailer must both be right.
            if let unpadded = stripPadding(compressed), let xml = try? inflateZlib(unpadded, verifyTrailer: true), !xml.isEmpty {
                return (xml, true)
            }
            // Lenient: some writers may not pad; the deflate stream's own end marker still delimits the data.
            if let xml = try? inflateZlib(compressed, verifyTrailer: false), !xml.isEmpty { return (xml, false) }
        }
        throw VaultError.wrongPassword
    }

    // MARK: Primitives

    private struct Reader {
        let data: Data
        var pos: Int

        init(_ data: Data) {
            self.data = Data(data)
            self.pos = 0
        }

        var rest: Data { data.subdata(in: pos..<data.count) }

        mutating func byte() throws -> UInt8 {
            guard pos < data.count else { throw VaultError.corrupted }
            defer { pos += 1 }
            return data[data.startIndex + pos]
        }

        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, pos + n <= data.count else { throw VaultError.corrupted }
            defer { pos += n }
            return data.subdata(in: pos..<(pos + n))
        }

        mutating func prefixed() throws -> Data { try bytes(Int(try byte())) }
    }

    static func pbkdf2(_ password: [UInt8], salt: Data, rounds: Int, length: Int, prf: CCPseudoRandomAlgorithm) -> Data? {
        var out = [UInt8](repeating: 0, count: length)
        let pw = password.map { Int8(bitPattern: $0) }
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                prf, UInt32(rounds), &out, length)
        }
        return status == kCCSuccess ? Data(out) : nil
    }

    static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard data.count % 16 == 0, !data.isEmpty else { return nil }
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,  // no padding: zlib marks the real end
                            keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                            inPtr.baseAddress, data.count, outPtr.baseAddress, data.count, &moved)
                    }
                }
            }
        }
        return status == kCCSuccess && moved == data.count ? out : nil
    }

    /// Standard zlib stream (2-byte header, deflate data, adler32). Trailing bytes after the stream are ignored.
    static func inflateZlib(_ data: Data, verifyTrailer: Bool) throws -> Data {
        guard data.count > 6, data[data.startIndex] & 0x0F == 8 else { throw VaultError.corrupted }
        let body = verifyTrailer ? data.dropLast(4) : data[...]
        let raw = Data(body.dropFirst(2))
        let bufferSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw VaultError.corrupted
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var failed = false
        raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { failed = true; return }
            stream.src_ptr = base
            stream.src_size = raw.count
            loop: while true {
                stream.dst_ptr = dst
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK:
                    output.append(dst, count: bufferSize - stream.dst_size)
                    // Input used up without the stream ending: truncated or damaged. Never accept partial data.
                    if stream.src_size == 0 && stream.dst_size > 0 { failed = true; break loop }
                case COMPRESSION_STATUS_END:
                    output.append(dst, count: bufferSize - stream.dst_size)
                    break loop
                default:
                    failed = true
                    break loop
                }
                if output.count > 512 * 1024 * 1024 { failed = true; break loop }  // sanity limit
            }
        }
        if failed { throw VaultError.corrupted }
        if verifyTrailer {
            // adler32 of the plain data, big endian, right after the deflate stream.
            let t = data.suffix(4)
            let stored = t.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard stored == adler32(output) else { throw VaultError.corrupted }
        }
        return output
    }

    /// Removes PKCS#7 padding, or returns nil when the padding is not valid (which means a wrong key).
    static func stripPadding(_ data: Data) -> Data? {
        guard let n = data.last.map(Int.init), (1...16).contains(n), data.count > n,
              data.suffix(n).allSatisfy({ Int($0) == n }) else { return nil }
        return data.dropLast(n)
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}

public extension SafeImporter {
    /// Decrypts Safe's own database file and reads it like an XML export.
    static func parse(safeDatabase file: Data, password: String, now: Date = Date()) throws -> ImportResult {
        let (xml, verified) = try SafeInCloudDatabase.decryptChecked(file, password: password)
        var result = try parseXML(data: xml, now: now)
        if !verified {
            result.warnings.append("Safe's file could not be integrity-checked. Compare the number of items with what you see in Safe.")
        }
        result.format = "Safe database"
        return result
    }
}
