import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MyVaultKit

func makePNG(size: Int, red: CGFloat = 0.2) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: red, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

func pixelSize(_ data: Data) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return (img.width, img.height)
}

final class SiteIconTests: XCTestCase {
    func testNormalizeShrinksAndKeepsItSmall() throws {
        let big = makePNG(size: 512)
        let out = try XCTUnwrap(SiteIcon.normalize(imageData: big))
        let (w, h) = try XCTUnwrap(pixelSize(out))
        XCTAssertLessThanOrEqual(max(w, h), SiteIcon.storedSize)
        XCTAssertLessThanOrEqual(out.count, SiteIcon.maxStoredBytes)
        let small = try XCTUnwrap(SiteIcon.normalize(imageData: makePNG(size: 32)))
        XCTAssertEqual(try XCTUnwrap(pixelSize(small)).0, 32, "never scaled up")
    }

    func testNormalizeRejectsJunk() {
        XCTAssertNil(SiteIcon.normalize(imageData: Data("not an image".utf8)))
        XCTAssertNil(SiteIcon.normalize(imageData: Data()))
        XCTAssertNil(SiteIcon.normalize(imageData: makePNG(size: 8)), "too tiny to be a logo")
    }

    func testPageURLIsAlwaysHTTPS() {
        XCTAssertEqual(SiteIcon.pageURL(from: "cabify.com/login?x=1")?.absoluteString, "https://cabify.com/login")
        XCTAssertEqual(SiteIcon.pageURL(from: "http://example.com")?.absoluteString, "https://example.com/")
        XCTAssertNil(SiteIcon.pageURL(from: ""))
        XCTAssertNil(SiteIcon.pageURL(from: "not a url"))
        XCTAssertNil(SiteIcon.pageURL(from: "localhost"))
    }

    func testCandidatesPreferTouchIconsAndSkipSVG() {
        let html = """
        <html><head>
        <link rel="icon" href="/favicon-16.png" sizes="16x16">
        <link rel="shortcut icon" href='/favicon.ico'>
        <link rel="icon" type="image/svg+xml" href="/logo.svg">
        <link rel="mask-icon" href="/mask.svg">
        <link rel="apple-touch-icon" sizes="180x180" href=/apple-180.png>
        <link rel="icon" href="//cdn.example.com/icon-64.png" sizes="64x64">
        <link rel="stylesheet" href="/style.css">
        </head></html>
        """
        let c = SiteIcon.candidates(in: html, base: URL(string: "https://www.example.com/login")!).map(\.url.absoluteString)
        XCTAssertEqual(c.first, "https://www.example.com/apple-180.png")
        XCTAssertTrue(c.contains("https://cdn.example.com/icon-64.png"))
        XCTAssertFalse(c.contains { $0.contains(".svg") || $0.contains("style.css") })
        XCTAssertLessThan(c.firstIndex(of: "https://cdn.example.com/icon-64.png")!, c.firstIndex(of: "https://www.example.com/favicon-16.png")!)
    }

    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    func testFetchFindsTheLogoFromTheSiteItself() async throws {
        let png = makePNG(size: 180)
        StubProtocol.seen = []
        StubProtocol.handler = { req in
            switch req.url!.path {
            case "/": return (200, ["Content-Type": "text/html"], Data(#"<link rel="apple-touch-icon" href="/touch.png">"#.utf8))
            case "/touch.png": return (200, ["Content-Type": "image/png"], png)
            default: return (404, [:], Data())
            }
        }
        let icon = await SiteIcon.fetch(website: "cabify.com", session: session())
        let out = try XCTUnwrap(icon)
        XCTAssertLessThanOrEqual(try XCTUnwrap(pixelSize(out)).0, 96)
        XCTAssertTrue(StubProtocol.seen.allSatisfy { $0.url?.host == "cabify.com" && $0.url?.scheme == "https" }, "only the site itself is contacted, only over https")
    }

    func testFetchFallsBackToFaviconAndGivesUpCleanly() async throws {
        let png = makePNG(size: 64)
        StubProtocol.handler = { req in req.url!.path == "/favicon.ico" ? (200, [:], png) : (404, [:], Data()) }
        let found = await SiteIcon.fetch(website: "example.org", session: session())
        XCTAssertNotNil(found)
        StubProtocol.handler = { _ in (404, [:], Data()) }
        let none = await SiteIcon.fetch(website: "example.org", session: session())
        XCTAssertNil(none)
        StubProtocol.handler = { _ in (200, [:], Data("<html>no icons</html>".utf8)) }
        let junk = await SiteIcon.fetch(website: "example.org", session: session())
        XCTAssertNil(junk)
    }

    // MARK: Items and sync

    func testOldItemsWithoutIconFieldsStillDecode() throws {
        let item = VaultItem(name: "Old", fields: [ItemField(label: "Password", value: "x", type: .secret)])
        var json = try JSONSerialization.jsonObject(with: VaultStorage.encoder.encode(item)) as! [String: Any]
        for k in ["icon", "iconCustom", "iconCheckedAt"] { json[k] = nil }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try VaultStorage.decoder.decode(VaultItem.self, from: data)
        XCTAssertNil(decoded.icon)
        XCTAssertEqual(decoded.name, "Old")
    }

    func testTwoDevicesFetchingDifferentIconBytesConverge() async throws {
        let remote = InMemoryRemote()
        let a = makeStorage(), b = makeStorage()
        defer { try? a.destroy(); try? b.destroy() }
        let sa = try VaultSession.create(password: "pw", storage: a, iterations: 1000)
        let base = loginItem("Cabify")
        try await sa.upsert(base)
        _ = try await SyncEngine(session: sa, remote: remote).sync()
        try b.installDownloadedHeader(try VaultFile.headerData(from: try await remote.download(VaultFile.name).data))
        let sb = try VaultSession.open(password: "pw", storage: b)
        _ = try await SyncEngine(session: sb, remote: remote).sync()

        // Both phones fetch the logo at the same time and get slightly different bytes.
        var ia = try await unwrapA(await sa.item(base.id)); ia.icon = makePNG(size: 64, red: 0.1); ia.iconCheckedAt = Date()
        var ib = try await unwrapA(await sb.item(base.id)); ib.icon = makePNG(size: 64, red: 0.3); ib.iconCheckedAt = Date()
        try await sa.upsert(ia, touch: false)
        try await sb.upsert(ib, touch: false)

        for _ in 0..<3 {
            _ = try await SyncEngine(session: sa, remote: remote).sync()
            _ = try await SyncEngine(session: sb, remote: remote).sync()
        }
        let fa = try await unwrapA(await sa.item(base.id)), fb = try await unwrapA(await sb.item(base.id))
        XCTAssertEqual(fa.icon, fb.icon, "both settle on the same icon")
        XCTAssertNotNil(fa.icon)
        let quiet = try await SyncEngine(session: sb, remote: remote).sync()
        XCTAssertEqual(quiet.pushed, 0, "and then stop uploading")
    }

    func testAChosenLogoBeatsADownloadedOne() async throws {
        var downloaded = loginItem("Site"); downloaded.icon = makePNG(size: 96, red: 0.1)
        var chosen = downloaded; chosen.icon = makePNG(size: 32, red: 0.9); chosen.iconCustom = true
        var merged = downloaded
        SyncEngine.applyBestIcon(&merged, downloaded, chosen)
        XCTAssertEqual(merged.icon, chosen.icon)
        XCTAssertEqual(merged.iconCustom, true)
        var other = downloaded
        SyncEngine.applyBestIcon(&other, chosen, downloaded)
        XCTAssertEqual(other.icon, merged.icon, "the order of the two copies does not matter")
    }
}
