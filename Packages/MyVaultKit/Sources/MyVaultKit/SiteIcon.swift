import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Finds a site's logo and shrinks it to a small PNG that is stored with the item.
///
/// Privacy: the logo is fetched from the site itself (its own page, `apple-touch-icon` or `favicon.ico`) and from
/// nowhere else. No favicon service ever learns which sites you have accounts on.
public enum SiteIcon {
    /// Longest side of a stored logo, and the size cap that keeps the vault small.
    public static let storedSize = 96
    public static let maxStoredBytes = 16_000

    struct Candidate: Equatable {
        var url: URL
        var score: Int
    }

    // MARK: Finding the logo

    public static func fetch(website: String, session: URLSession = .shared) async -> Data? {
        guard let page = pageURL(from: website) else { return nil }
        var urls = [URL]()
        var base = page
        if let (html, finalURL) = await get(page, limit: 400_000, session: session) {
            base = finalURL
            urls = candidates(in: String(decoding: html, as: UTF8.self), base: finalURL).map(\.url)
        }
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            if let u = URL(string: path, relativeTo: base)?.absoluteURL, !urls.contains(u) { urls.append(u) }
        }
        for url in urls.prefix(5) {
            guard let (data, _) = await get(url, limit: 1_500_000, session: session),
                  let png = normalize(imageData: data) else { continue }
            return png
        }
        return nil
    }

    static func pageURL(from website: String) -> URL? {
        let trimmed = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var c = URLComponents(string: withScheme), let host = c.host, host.contains(".") else { return nil }
        c.scheme = "https"  // never send the request in the clear
        c.path = c.path.isEmpty ? "/" : c.path
        c.query = nil
        c.fragment = nil
        return c.url
    }

    private static func get(_ url: URL, limit: Int, session: URLSession) async -> (Data, URL)? {
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 SafeVault", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= limit else { return nil }
        return (data, http.url ?? url)
    }

    /// The icon links of a page, best first: big `apple-touch-icon` images, then the largest `icon`.
    static func candidates(in html: String, base: URL) -> [Candidate] {
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var result = [Candidate]()
        for m in tags.matches(in: html, range: range) {
            guard let r = Range(m.range, in: html) else { continue }
            let tag = String(html[r])
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"), !rel.contains("mask-icon"),
                  let href = attribute("href", in: tag), !href.hasPrefix("data:"),
                  !href.lowercased().contains(".svg"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let size = (attribute("sizes", in: tag) ?? "").lowercased().split(separator: "x").first.flatMap { Int($0) } ?? 16
            result.append(Candidate(url: url, score: (rel.contains("apple-touch-icon") ? 1000 : 0) + min(size, 512)))
        }
        // Stable order: higher score first, then the order in the page.
        return result.enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }.map(\.element)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for i in 1...3 { if let r = Range(m.range(at: i), in: tag) { return String(tag[r]) } }
        return nil
    }

    // MARK: Shrinking an image

    /// Decodes any common image (PNG, JPEG, ICO, HEIC...) and returns a small PNG, or nil when it is unusable.
    public static func normalize(imageData: Data, maxDimension: Int = storedSize, maxBytes: Int = maxStoredBytes) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        var best: CGImage?
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            if best == nil || image.width * image.height > best!.width * best!.height { best = image }  // largest frame of an .ico
        }
        guard let image = best, image.width >= 16, image.height >= 16 else { return nil }
        for dimension in [maxDimension, 64, 48] where dimension <= maxDimension {
            if let png = png(of: image, fitting: dimension), png.count <= maxBytes { return png }
        }
        return nil
    }

    private static func png(of image: CGImage, fitting dimension: Int) -> Data? {
        let scale = min(1, CGFloat(dimension) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int((CGFloat(image.width) * scale).rounded())), h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
