// Draws the app icon with CoreGraphics and writes PNGs at the requested sizes.
// Usage: swift icon/make_icon.swift <mac|full> <size> <out.png> [<size> <out.png> ...]
//   mac:  macOS layout (rounded tile inset on the canvas, with drop shadow)
//   full: tile fills the canvas (Windows .ico, previews)
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

func capsule(_ rect: CGRect) -> CGPath {
    let r = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

func star(_ c: CGContext, at p: CGPoint, size s: CGFloat, alpha: CGFloat) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: p.x, y: p.y - s))
    path.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), control: p)
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), control: p)
    path.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), control: p)
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), control: p)
    c.addPath(path)
    c.setFillColor(rgb(0xFFFFFF, alpha))
    c.fillPath()
}

// Everything is laid out on a 1024-point canvas with a top-left origin.
func drawIcon(_ c: CGContext, mac: Bool) {
    let tile = mac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let corner: CGFloat = mac ? 185 : 200
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    if mac {
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
        c.addPath(tilePath)
        c.setFillColor(rgb(0x10133A))
        c.fillPath()
        c.restoreGState()
    }

    c.saveGState()
    c.addPath(tilePath)
    c.clip()

    // Night-concert backdrop.
    c.drawLinearGradient(gradient([(0x23205E, 1, 0), (0x121443, 1, 0.55), (0x07081E, 1, 1)]),
                         start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])

    // The stick: tilted, light tip toward the top right.
    let center = CGPoint(x: 425, y: 590)
    let angle = CGFloat(32) * .pi / 180
    let k: CGFloat = 0.9
    let tipCenter = CGPoint(x: center.x + sin(angle) * 300 * k, y: center.y - cos(angle) * 300 * k)

    // Colored halo around the light (cyan core fading to violet).
    c.drawRadialGradient(gradient([(0x5FE3FF, 0.55, 0), (0x3D6BFF, 0.35, 0.4), (0x8A3DFF, 0.18, 0.7), (0x8A3DFF, 0, 1)]),
                         startCenter: tipCenter, startRadius: 0, endCenter: tipCenter, endRadius: 520, options: [])

    // Signal arcs past the tip.
    c.saveGState()
    c.translateBy(x: tipCenter.x, y: tipCenter.y)
    c.rotate(by: angle)
    c.scaleBy(x: k, y: k)
    c.setLineCap(.round)
    for (i, radius) in [CGFloat(125), 180, 235].enumerated() {
        c.setStrokeColor(rgb(0xFFFFFF, 0.9 - CGFloat(i) * 0.22))
        c.setLineWidth(26)
        c.addArc(center: .zero, radius: radius, startAngle: -.pi / 2 - 0.42, endAngle: -.pi / 2 + 0.42, clockwise: false)
        c.strokePath()
    }
    c.restoreGState()

    // The screen the light follows, glowing in the same colors.
    let screen = CGRect(x: 615, y: 590, width: 260, height: 180)
    c.saveGState()
    c.setShadow(offset: .zero, blur: 60, color: rgb(0x48C8FF, 0.6))
    c.addPath(CGPath(roundedRect: screen, cornerWidth: 28, cornerHeight: 28, transform: nil))
    c.setFillColor(rgb(0x2A2E48))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(CGPath(roundedRect: screen.insetBy(dx: 16, dy: 16), cornerWidth: 14, cornerHeight: 14, transform: nil))
    c.clip()
    c.drawLinearGradient(gradient([(0x7FE6FF, 1, 0), (0x3D8BFF, 1, 0.55), (0x6A4DFF, 1, 1)]),
                         start: CGPoint(x: screen.minX, y: screen.minY), end: CGPoint(x: screen.maxX, y: screen.maxY), options: [])
    c.restoreGState()
    c.setFillColor(rgb(0x2A2E48))
    c.fill(CGRect(x: screen.midX - 18, y: screen.maxY, width: 36, height: 44))
    c.addPath(capsule(CGRect(x: screen.midX - 70, y: screen.maxY + 38, width: 140, height: 22)))
    c.fillPath()

    c.saveGState()
    c.translateBy(x: center.x, y: center.y)
    c.rotate(by: angle)
    c.scaleBy(x: k, y: k)

    // Light tube (top) with glow.
    let tube = CGRect(x: -66, y: -380, width: 132, height: 470)
    for (blur, alpha) in [(CGFloat(120), CGFloat(0.9)), (40, 0.9)] {
        c.saveGState()
        c.setShadow(offset: .zero, blur: blur, color: rgb(0x48C8FF, alpha))
        c.addPath(capsule(tube))
        c.setFillColor(rgb(0x48C8FF))
        c.fillPath()
        c.restoreGState()
    }
    c.saveGState()
    c.addPath(capsule(tube))
    c.clip()
    c.drawLinearGradient(gradient([(0xE9FDFF, 1, 0), (0x7FE6FF, 1, 0.25), (0x3D8BFF, 1, 0.7), (0x6A4DFF, 1, 1)]),
                         start: CGPoint(x: 0, y: tube.minY), end: CGPoint(x: 0, y: tube.maxY), options: [])
    // Bright core.
    c.setShadow(offset: .zero, blur: 24, color: rgb(0xFFFFFF, 1))
    c.addPath(capsule(CGRect(x: -20, y: -350, width: 40, height: 380)))
    c.setFillColor(rgb(0xFFFFFF, 0.9))
    c.fillPath()
    c.restoreGState()

    // Collar ring.
    let collar = CGRect(x: -80, y: 80, width: 160, height: 50)
    c.saveGState()
    c.addPath(CGPath(roundedRect: collar, cornerWidth: 18, cornerHeight: 18, transform: nil))
    c.clip()
    c.drawLinearGradient(gradient([(0x9AA3C7, 1, 0), (0xF4F6FF, 1, 0.35), (0x6E7699, 1, 1)]),
                         start: CGPoint(x: collar.minX, y: 0), end: CGPoint(x: collar.maxX, y: 0), options: [])
    c.restoreGState()

    // Handle.
    let handle = CGRect(x: -68, y: 128, width: 136, height: 230)
    c.saveGState()
    c.addPath(CGPath(roundedRect: handle, cornerWidth: 40, cornerHeight: 40, transform: nil))
    c.clip()
    c.drawLinearGradient(gradient([(0x2A2E48, 1, 0), (0x585F86, 1, 0.4), (0x1A1C2E, 1, 1)]),
                         start: CGPoint(x: handle.minX, y: 0), end: CGPoint(x: handle.maxX, y: 0), options: [])
    c.restoreGState()
    // Button.
    c.addEllipse(in: CGRect(x: -22, y: 190, width: 44, height: 44))
    c.setFillColor(rgb(0x5FE3FF, 0.95))
    c.fillPath()

    c.restoreGState()

    star(c, at: CGPoint(x: 250, y: 300), size: 34, alpha: 0.85)
    star(c, at: CGPoint(x: 330, y: 200), size: 18, alpha: 0.6)

    // Subtle top sheen on the tile.
    c.drawLinearGradient(gradient([(0xFFFFFF, 0.10, 0), (0xFFFFFF, 0, 0.45)]),
                         start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    c.restoreGState()
}

func render(mac: Bool, size: Int, to url: URL) {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    let scale = CGFloat(size) / 1024
    c.translateBy(x: 0, y: CGFloat(size))
    c.scaleBy(x: scale, y: -scale)
    drawIcon(c, mac: mac)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest), "could not write \(url.path)")
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3, args.count % 2 == 1, ["mac", "full"].contains(args[0]) else {
    FileHandle.standardError.write("usage: make_icon.swift <mac|full> <size> <out.png> ...\n".data(using: .utf8)!)
    exit(2)
}
for i in stride(from: 1, to: args.count, by: 2) {
    render(mac: args[0] == "mac", size: Int(args[i])!, to: URL(fileURLWithPath: args[i + 1]))
}
