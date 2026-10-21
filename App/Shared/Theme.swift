import MyVaultKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

/// Design tokens, taken from the web design (light mode only for now).
enum VT {
    static let ink = Color(hex: 0x161A22)
    static let ink2 = Color(hex: 0x5B6475)
    static let ink3 = Color(hex: 0x97A0B0)
    static let line = Color(hex: 0x16203F, opacity: 0.08)
    static let fill = Color(hex: 0xE9EDF4)
    static let blue = Color(hex: 0x2F73F2)
    static let blueSoft = Color(hex: 0xE7EFFE)
    static let green = Color(hex: 0x1FB16B)
    static let greenSoft = Color(hex: 0xE4F6EC)
    static let violet = Color(hex: 0x7A68E8)
    static let violetSoft = Color(hex: 0xEEEBFC)
    static let amber = Color(hex: 0xF5A524)
    static let red = Color(hex: 0xF0524A)
    static let star = Color(hex: 0xFFB020)
    static let background = Color(hex: 0xF3F5F9)
    static let detailBackground = Color(hex: 0xF8F9FC)
    static let sidebar = Color(hex: 0xF1F3F8)
    static let surface = Color.white

    static func color(for level: StrengthLevel) -> Color {
        switch level {
        case .strong: green
        case .good: Color(hex: 0x3FB950)
        case .fair: amber
        case .weak: red
        }
    }

    static let appGradient = LinearGradient(
        colors: [Color(hex: 0x4B8BFF), Color(hex: 0x2F6BEF)], startPoint: .top, endPoint: .bottom)
}

// MARK: - Containers

struct VaultCard<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VT.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(VT.line))
            .shadow(color: Color(hex: 0x16203F, opacity: 0.03), radius: 1, y: 1)
    }
}

struct Pill: View {
    let text: String
    var foreground: Color = VT.blue
    var background: Color = VT.blueSoft

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct StatusPill: View {
    let text: String
    var good = true

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(good ? Color(hex: 0x148A52) : VT.ink3)
            .padding(.horizontal, 11)
            .padding(.vertical, 3)
            .background(good ? VT.greenSoft : VT.fill, in: Capsule())
    }
}

struct StrengthBar: View {
    let level: StrengthLevel
    let score: Double

    var body: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(VT.fill)
                    Capsule().fill(VT.color(for: level)).frame(width: max(6, geo.size.width * score))
                }
            }
            .frame(height: 4)
            Text(level.label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(VT.color(for: level))
                .fixedSize()
        }
    }
}

/// Shield with a keyhole cut out. Drawn in a unit square so it scales cleanly.
struct ShieldKeyholeShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0.5, 0.06))
        path.addCurve(to: p(0.88, 0.17), control1: p(0.62, 0.14), control2: p(0.78, 0.17))
        path.addLine(to: p(0.88, 0.50))
        path.addCurve(to: p(0.5, 0.95), control1: p(0.88, 0.72), control2: p(0.72, 0.86))
        path.addCurve(to: p(0.12, 0.50), control1: p(0.28, 0.86), control2: p(0.12, 0.72))
        path.addLine(to: p(0.12, 0.17))
        path.addCurve(to: p(0.5, 0.06), control1: p(0.22, 0.17), control2: p(0.38, 0.14))
        path.closeSubpath()
        // Keyhole as one outline (round head flowing into a tapered stem), so nothing overlaps.
        let cx: CGFloat = 0.5, cy: CGFloat = 0.42, rr: CGFloat = 0.075
        let a0 = 40.0 * .pi / 180, sweep = 280.0 * .pi / 180
        path.move(to: p(cx + rr * sin(a0), cy + rr * cos(a0)))
        let steps = 64
        for i in 1...steps {
            let t = a0 + sweep * CGFloat(i) / CGFloat(steps)
            path.addLine(to: p(cx + rr * sin(t), cy + rr * cos(t)))
        }
        path.addLine(to: p(0.44, 0.68))
        path.addQuadCurve(to: p(0.56, 0.68), control: p(0.5, 0.70))
        path.closeSubpath()
        return path
    }
}

struct AppMark: View {
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(VT.appGradient)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom), lineWidth: max(1, size * 0.012))
            )
            .overlay(
                ShieldKeyholeShape()
                    .fill(.white, style: FillStyle(eoFill: true))
                    .frame(width: size * 0.62, height: size * 0.62)
                    .shadow(color: Color(hex: 0x1B3FA8, opacity: 0.35), radius: size * 0.03, y: size * 0.02)
            )
            .shadow(color: VT.blue.opacity(size > 40 ? 0.35 : 0), radius: size * 0.2, y: size * 0.1)
            .accessibilityHidden(true)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : VT.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? VT.blue : VT.surface)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(prominent ? .clear : VT.line))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

// MARK: - Service tile

private enum Glyph {
    case letter(String)
    case symbol(String)
    case dropbox
    case google
    case netflix
}

private struct Brand {
    var background: Color
    var foreground: Color = .white
    var glyph: Glyph
    var hairline = false
}

private final class BrandCache: @unchecked Sendable {
    static let shared = BrandCache()
    private var values = [String: Brand]()
    private let lock = NSLock()

    func brand(for name: String, kind: ItemKind) -> Brand {
        let key = "\(kind.rawValue)|\(name)"
        lock.lock(); defer { lock.unlock() }
        if let hit = values[key] { return hit }
        let made = makeBrand(for: name, kind: kind)
        values[key] = made
        return made
    }
}

private func brand(for name: String, kind: ItemKind) -> Brand { BrandCache.shared.brand(for: name, kind: kind) }

private func makeBrand(for name: String, kind: ItemKind) -> Brand {
    let n = name.lowercased()
    func has(_ s: String) -> Bool { n.contains(s) }
    switch kind {
    case .card: return Brand(background: Color(hex: 0xE8EEFC), foreground: Color(hex: 0x2F5FD0), glyph: .symbol("creditcard.fill"))
    case .wifi: return Brand(background: Color(hex: 0xEFEAFD), foreground: Color(hex: 0x6B58D8), glyph: .symbol("wifi"))
    case .identity: return Brand(background: Color(hex: 0xE4F6EC), foreground: Color(hex: 0x1C9A5F), glyph: .symbol("person.text.rectangle.fill"))
    case .note: return Brand(background: Color(hex: 0xFDF0DC), foreground: Color(hex: 0xC47A0A), glyph: .symbol("note.text"))
    case .login: break
    }
    if has("google") || has("gmail") { return Brand(background: .white, glyph: .google, hairline: true) }
    if has("apple") || has("icloud") { return Brand(background: Color(hex: 0x1D1D1F), glyph: .symbol("apple.logo")) }
    if has("dropbox") { return Brand(background: Color(hex: 0x0061FF), glyph: .dropbox) }
    if has("netflix") { return Brand(background: Color(hex: 0x0B0B0D), glyph: .netflix) }
    if has("amazon") { return Brand(background: .white, foreground: Color(hex: 0x111827), glyph: .letter("a"), hairline: true) }
    if has("airbnb") { return Brand(background: Color(hex: 0xFF385C), glyph: .symbol("heart.fill")) }
    if has("asana") { return Brand(background: .white, foreground: Color(hex: 0xF95353), glyph: .symbol("circle.grid.3x3.fill"), hairline: true) }
    if has("booking") { return Brand(background: Color(hex: 0x003B95), glyph: .letter("B.")) }
    if has("discord") { return Brand(background: Color(hex: 0x5865F2), glyph: .symbol("gamecontroller.fill")) }
    if has("figma") { return Brand(background: Color(hex: 0x1E1E22), glyph: .symbol("square.on.circle.fill")) }
    if has("fitness") { return Brand(background: Color(hex: 0x141416), foreground: Color(hex: 0xB6F23C), glyph: .symbol("figure.run")) }
    if has("github") { return Brand(background: Color(hex: 0x1B1F24), glyph: .symbol("chevron.left.forwardslash.chevron.right")) }
    if has("spotify") { return Brand(background: Color(hex: 0x1DB954), glyph: .symbol("music.note")) }
    if has("twitter") || n == "x" { return Brand(background: .black, glyph: .letter("X")) }

    // Anything else: a calm letter tile whose colour comes from the name.
    let palette: [UInt32] = [0x2F73F2, 0x7A68E8, 0x1FB16B, 0xF08A24, 0xE5566D, 0x14A3B8, 0x5B6475]
    var hash = 5381
    for u in n.unicodeScalars { hash = (hash &* 33) &+ Int(u.value) }
    let c = palette[abs(hash) % palette.count]
    let letter = String(name.trimmingCharacters(in: .whitespaces).first.map { Character($0.uppercased()) } ?? "?")
    return Brand(background: Color(hex: c), glyph: .letter(letter))
}

#if canImport(UIKit)
import UIKit
private typealias PlatformImage = UIImage
#else
import AppKit
private typealias PlatformImage = NSImage
#endif

/// Decoded logos, kept in memory so scrolling a long list does not decode a PNG per row per frame.
private final class IconImageCache: @unchecked Sendable {
    static let shared = IconImageCache()
    private let cache = NSCache<NSData, PlatformImage>()

    func image(for data: Data) -> PlatformImage? {
        let key = data as NSData
        if let hit = cache.object(forKey: key) { return hit }
        guard let made = PlatformImage(data: data) else { return nil }
        cache.setObject(made, forKey: key)
        return made
    }
}

private func logoImage(_ data: Data) -> Image? {
    guard let image = IconImageCache.shared.image(for: data) else { return nil }
    #if canImport(UIKit)
    return Image(uiImage: image)
    #else
    return Image(nsImage: image)
    #endif
}

struct ServiceTile: View {
    let name: String
    var kind: ItemKind = .login
    /// The site's logo or the one you chose. Takes the place of the generic tile.
    var icon: Data? = nil
    var size: CGFloat = 40

    var body: some View {
        if let icon, let image = logoImage(icon) {
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(size * 0.1)
                .frame(width: size, height: size)
                .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(VT.line))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                .accessibilityHidden(true)
        } else {
            genericTile
        }
    }

    @ViewBuilder private var genericTile: some View {
        let b = brand(for: name, kind: kind)
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(b.background)
            .overlay(glyph(b))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .strokeBorder(b.hairline ? VT.line : .clear))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func glyph(_ b: Brand) -> some View {
        switch b.glyph {
        case .letter(let s):
            Text(s).font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundStyle(b.foreground)
        case .symbol(let s):
            Image(systemName: s).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(b.foreground)
        case .dropbox:
            DropboxMark().fill(.white).frame(width: size * 0.56, height: size * 0.56)
        case .google:
            GoogleMark().frame(width: size * 0.5, height: size * 0.5)
        case .netflix:
            NetflixMark().frame(width: size * 0.36, height: size * 0.5)
        }
    }
}

private struct DropboxMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        func diamond(_ cx: CGFloat, _ cy: CGFloat) {
            p.move(to: CGPoint(x: r.minX + cx * w, y: r.minY + (cy - 0.17) * h))
            p.addLine(to: CGPoint(x: r.minX + (cx + 0.25) * w, y: r.minY + cy * h))
            p.addLine(to: CGPoint(x: r.minX + cx * w, y: r.minY + (cy + 0.17) * h))
            p.addLine(to: CGPoint(x: r.minX + (cx - 0.25) * w, y: r.minY + cy * h))
            p.closeSubpath()
        }
        diamond(0.25, 0.18)
        diamond(0.75, 0.18)
        diamond(0.25, 0.52)
        diamond(0.75, 0.52)
        diamond(0.5, 0.86)
        return p
    }
}

private struct GoogleMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            let lw = s * 0.26
            ZStack {
                arc(0.0, 0.144, Color(hex: 0x4285F4), lw)
                arc(0.144, 0.403, Color(hex: 0x34A853), lw)
                arc(0.403, 0.611, Color(hex: 0xFBBC05), lw)
                arc(0.611, 0.883, Color(hex: 0xEA4335), lw)
                Rectangle().fill(Color(hex: 0x4285F4))
                    .frame(width: s / 2 - lw * 0.1, height: lw)
                    .position(x: s * 0.75 - lw * 0.05, y: s / 2)
            }
            .frame(width: s, height: s)
        }
    }

    private func arc(_ from: CGFloat, _ to: CGFloat, _ color: Color, _ lw: CGFloat) -> some View {
        Circle().trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .butt))
            .padding(lw / 2)
    }
}

private struct NetflixMark: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let bar = w * 0.3
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: bar, y: 0))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w - bar, y: h))
                    p.closeSubpath()
                }.fill(Color(hex: 0xB20710))
                Rectangle().fill(Color(hex: 0xE50914)).frame(width: bar, height: h).position(x: bar / 2, y: h / 2)
                Rectangle().fill(Color(hex: 0xE50914)).frame(width: bar, height: h).position(x: w - bar / 2, y: h / 2)
            }
        }
    }
}
