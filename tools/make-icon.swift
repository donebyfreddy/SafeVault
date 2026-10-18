// Renders the SafeVault app icon masters.
//   swift make-icon.swift <outDir>                  -> logo icon (shield + keyhole)
//   swift make-icon.swift <outDir> <photo>          -> your photo, with the shield as a badge
//   swift make-icon.swift <outDir> <photo> <x> <y> <size>
//        crop focus: x, y = centre of the crop as fractions of the photo (y from the top), size = side as a
//        fraction of the shorter photo side. Example for a full-body photo: 0.5 0.235 0.55 (head and shoulders).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make-icon.swift <outDir> [photo]"); exit(1) }
let outDir = args[1]
let photoPath = args.count > 2 ? args[2] : nil
let focus: (x: CGFloat, y: CGFloat, size: CGFloat)? = args.count > 5
    ? (CGFloat(Double(args[3]) ?? 0.5), CGFloat(Double(args[4]) ?? 0.5), CGFloat(Double(args[5]) ?? 1)) : nil
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

/// Shield + keyhole in a unit square (y down), same geometry as the in-app mark.
func shieldPath(in rect: CGRect) -> CGPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.maxY - y * rect.height) }
    let path = CGMutablePath()
    path.move(to: p(0.5, 0.06))
    path.addCurve(to: p(0.88, 0.17), control1: p(0.62, 0.14), control2: p(0.78, 0.17))
    path.addLine(to: p(0.88, 0.50))
    path.addCurve(to: p(0.5, 0.95), control1: p(0.88, 0.72), control2: p(0.72, 0.86))
    path.addCurve(to: p(0.12, 0.50), control1: p(0.28, 0.86), control2: p(0.12, 0.72))
    path.addLine(to: p(0.12, 0.17))
    path.addCurve(to: p(0.5, 0.06), control1: p(0.22, 0.17), control2: p(0.38, 0.14))
    path.closeSubpath()
    return path
}

func keyholePath(in rect: CGRect) -> CGPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.maxY - y * rect.height) }
    // One outline: round head flowing into a tapered stem.
    let path = CGMutablePath()
    let cx: CGFloat = 0.5, cy: CGFloat = 0.42, rr: CGFloat = 0.075
    let a0 = 40.0 * CGFloat.pi / 180, sweep = 280.0 * CGFloat.pi / 180
    path.move(to: p(cx + rr * sin(a0), cy + rr * cos(a0)))
    for i in 1...64 {
        let t = a0 + sweep * CGFloat(i) / 64
        path.addLine(to: p(cx + rr * sin(t), cy + rr * cos(t)))
    }
    path.addLine(to: p(0.44, 0.68))
    path.addQuadCurve(to: p(0.56, 0.68), control: p(0.5, 0.70))
    path.closeSubpath()
    return path
}

func drawShield(_ ctx: CGContext, in rect: CGRect, fill: CGColor, hole: CGColor, shadow: Bool) {
    ctx.saveGState()
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.025), blur: rect.height * 0.06, color: color(10, 30, 120, 0.4)) }
    ctx.addPath(shieldPath(in: rect))
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(keyholePath(in: rect))
    ctx.setFillColor(hole)
    ctx.fillPath()
}

func loadPhoto(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let opts = Optional([kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary)
    else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
}

func render(size: Int, mac: Bool, photo: CGImage?, to path: String) {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let box = mac ? CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804) : CGRect(x: 0, y: 0, width: s, height: s)
    let corner = box.width * 0.225
    let squircle = CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil)

    if mac {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: photo == nil ? color(20, 40, 110, 0.35) : color(0, 0, 0, 0.30))
        ctx.addPath(squircle); ctx.setFillColor(photo == nil ? color(37, 71, 208) : color(20, 22, 30)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(squircle); ctx.clip()
    }

    if let photo {
        // Centre-crop the photo to a square that fills the icon.
        let w = CGFloat(photo.width), h = CGFloat(photo.height)
        let side = min(w, h) * min(1, max(0.1, focus?.size ?? 1))
        let cx = (focus?.x ?? 0.5) * w, cy = (focus?.y ?? 0.5) * h
        let crop = CGRect(
            x: min(max(0, cx - side / 2), w - side), y: min(max(0, cy - side / 2), h - side),
            width: side, height: side)
        if let cropped = photo.cropping(to: crop) { ctx.draw(cropped, in: box) }
        // A soft shade at the bottom helps the badge read on any photo.
        let shade = CGGradient(colorsSpace: cs, colors: [color(0, 0, 0, 0), color(5, 15, 60, 0.55)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: box.midY), end: CGPoint(x: 0, y: box.minY), options: [])
        // Badge: blue disc with the shield, bottom right.
        let d = box.width * 0.40
        let disc = CGRect(x: box.maxX - d - box.width * 0.06, y: box.minY + box.width * 0.06, width: d, height: d)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -d * 0.04), blur: d * 0.12, color: color(0, 10, 60, 0.5))
        ctx.addEllipse(in: disc); ctx.setFillColor(color(255, 255, 255)); ctx.fillPath()
        ctx.restoreGState()
        let inner = disc.insetBy(dx: d * 0.05, dy: d * 0.05)
        ctx.saveGState()
        ctx.addEllipse(in: inner); ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [color(75, 139, 255), color(37, 71, 208)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: inner.maxY), end: CGPoint(x: 0, y: inner.minY), options: [])
        ctx.restoreGState()
        drawShield(ctx, in: inner.insetBy(dx: inner.width * 0.14, dy: inner.height * 0.14), fill: color(255, 255, 255), hole: color(47, 100, 230), shadow: false)
    } else {
        let g = CGGradient(colorsSpace: cs, colors: [color(86, 150, 255), color(34, 66, 205)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
        // Soft light from the top and a thin inner rim give it depth.
        let glow = CGGradient(colorsSpace: cs, colors: [color(255, 255, 255, 0.22), color(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: box.midX, y: box.maxY), startRadius: 0, endCenter: CGPoint(x: box.midX, y: box.maxY), endRadius: box.width * 0.75, options: [])
        // Faint dial ring behind the shield, a nod to a vault door.
        ctx.setStrokeColor(color(255, 255, 255, 0.14)); ctx.setLineWidth(box.width * 0.012)
        ctx.addEllipse(in: CGRect(x: box.midX - box.width * 0.40, y: box.midY - box.width * 0.40, width: box.width * 0.80, height: box.width * 0.80)); ctx.strokePath()
        ctx.setStrokeColor(color(255, 255, 255, 0.08)); ctx.setLineWidth(box.width * 0.008)
        ctx.addEllipse(in: CGRect(x: box.midX - box.width * 0.45, y: box.midY - box.width * 0.45, width: box.width * 0.90, height: box.width * 0.90)); ctx.strokePath()
        let sh = CGRect(x: box.midX - box.width * 0.30, y: box.midY - box.width * 0.30, width: box.width * 0.60, height: box.width * 0.60)
        drawShield(ctx, in: sh, fill: color(255, 255, 255), hole: color(40, 82, 214), shadow: true)
    }

    guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

var photo: CGImage? = nil
if let photoPath {
    guard let p = loadPhoto(photoPath) else { print("Could not read the photo at \(photoPath)"); exit(2) }
    photo = p
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
render(size: 1024, mac: false, photo: photo, to: "\(outDir)/ios-1024.png")
render(size: 1024, mac: true, photo: photo, to: "\(outDir)/mac-1024.png")
print("done")
