// Renders the app icons: an original skeuomorphic "clipboard robot" (purple board, lined paper,
// metal clip, eyes, Wi-Fi badge) in the spirit of Pastebot's style. Not Tapbots' artwork; no SF Symbols.
//   swift scripts/render-icons.swift
// Writes iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png and AppIcon-Dark.png (1024, full bleed;
// the dark one is the iOS dark-appearance variant) and
// Mac/Assets.xcassets/AppIcon.appiconset/mac-1024.png (rounded-square macOS shape). After
// re-rendering, regenerate the smaller Mac sizes, e.g.:
//   cd Mac/Assets.xcassets/AppIcon.appiconset && for p in 16 32 64 128 256 512; do sips -z $p $p mac-1024.png --out mac-$p.png; done
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func gradient(_ colors: [UInt32]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors.map { color($0) } as CFArray, locations: nil)!
}

/// Every colour the drawing uses, so the dark-appearance variant is the same artwork re-inked.
struct Palette {
    var board: [UInt32]          // top → bottom
    var boardShadowFill: UInt32
    var backSheets: [UInt32]     // lowest sheet first
    var sheet: [UInt32]
    var rule: UInt32
    var header: [UInt32]
    var headerEdge: UInt32
    var ringFill: UInt32
    var ringStroke: UInt32
    var ringHole: UInt32
    var eyeBase: UInt32
    var eye: [UInt32]
    var eyeHighlight: UInt32
    var badge: [UInt32]
    var badgeShadow: UInt32
    var signal: UInt32

    static let light = Palette(
        board: [0x9D7BFF, 0x7A54E6, 0x5533B8], boardShadowFill: 0x4A2C9E,
        backSheets: [0xC5CBD3, 0xDDE1E6], sheet: [0xFFFFFF, 0xF1F3F6], rule: 0xDCE1E7,
        header: [0xF4F6F8, 0xD5DAE0, 0xBCC3CC], headerEdge: 0x2A3139,
        ringFill: 0xE3E7EC, ringStroke: 0x8C96A3, ringHole: 0x5533B8,
        eyeBase: 0x101317, eye: [0x3A424C, 0x15191E, 0x0A0C0F], eyeHighlight: 0xFFFFFF,
        badge: [0xFFFFFF, 0xECE6FB], badgeShadow: 0x2A1466, signal: 0x6A43D9)

    /// Near-black board with a purple cast, graphite paper, and the purple moved into the glowing
    /// eyes and the badge so the icon still reads as the same character.
    static let dark = Palette(
        board: [0x2E2748, 0x1D1930, 0x100E1A], boardShadowFill: 0x0B0912,
        backSheets: [0x23252B, 0x2D3037], sheet: [0x444852, 0x353840], rule: 0x51555F,
        header: [0x7B818C, 0x5E646E, 0x484D56], headerEdge: 0x14161A,
        ringFill: 0x6C727C, ringStroke: 0x3A3E46, ringHole: 0x100E1A,
        eyeBase: 0xC2ADFF, eye: [0xE9E1FF, 0xC2ADFF, 0x9D7BFF], eyeHighlight: 0xFFFFFF,
        badge: [0x9A78FF, 0x6A43D9], badgeShadow: 0x000000, signal: 0xFFFFFF)
}

func render(size: Int, mac: Bool, palette: Palette = .light) -> CGImage {
    let s = CGFloat(size)
    // iOS icons must not have an alpha channel (App Store Connect rejects them); macOS needs it for
    // the transparent margin around the rounded square.
    let alpha: CGImageAlphaInfo = mac ? .premultipliedLast : .noneSkipLast
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: alpha.rawValue)!

    // iOS: full-bleed square (the system masks it). macOS: 824/1024 rounded square with drop shadow.
    var canvas = CGRect(x: 0, y: 0, width: s, height: s)
    if mac {
        let inset = s * 100 / 1024
        canvas = CGRect(x: inset, y: inset + s * 0.01, width: s - 2 * inset, height: s - 2 * inset)
    }
    let u = canvas.width
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: canvas.minX + x * u, y: canvas.minY + y * u, width: w * u, height: h * u)
    }
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: canvas.minX + x * u, y: canvas.minY + y * u)
    }
    func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: radius * u, cornerHeight: radius * u, transform: nil)
    }
    func fillVertical(_ path: CGPath, _ g: CGGradient, top: CGFloat, bottom: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(g, start: point(0.5, top), end: point(0.5, bottom), options: [])
        ctx.restoreGState()
    }

    // MARK: Board (purple, lighter at the top for a soft bevel)
    let boardPath = mac
        ? CGPath(roundedRect: canvas, cornerWidth: u * 0.225, cornerHeight: u * 0.225, transform: nil)
        : CGPath(rect: canvas, transform: nil)
    if mac {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.025, color: color(0x000000, 0.35))
        ctx.addPath(boardPath)
        ctx.setFillColor(color(palette.boardShadowFill))
        ctx.fillPath()
        ctx.restoreGState()
    }
    fillVertical(boardPath, gradient(palette.board), top: 1, bottom: 0)
    if mac {
        // Inner rim highlight.
        ctx.addPath(CGPath(roundedRect: canvas.insetBy(dx: u * 0.012, dy: u * 0.012),
                           cornerWidth: u * 0.21, cornerHeight: u * 0.21, transform: nil))
        ctx.setStrokeColor(color(0xFFFFFF, 0.18))
        ctx.setLineWidth(u * 0.012)
        ctx.strokePath()
    }

    // MARK: Paper stack
    let sheet = rect(0.18, 0.17, 0.64, 0.62)
    // Back sheets peeking out below.
    for (offset, shade) in zip([0.045, 0.024] as [CGFloat], palette.backSheets) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.01), blur: u * 0.03, color: color(0x0E1C2C, 0.35))
        ctx.addPath(rounded(sheet.offsetBy(dx: 0, dy: -offset * u).insetBy(dx: offset * 0.4 * u, dy: 0), 0.06))
        ctx.setFillColor(color(shade))
        ctx.fillPath()
        ctx.restoreGState()
    }
    let sheetPath = rounded(sheet, 0.06)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.006), blur: u * 0.02, color: color(0x0E1C2C, 0.3))
    ctx.addPath(sheetPath)
    ctx.setFillColor(color(palette.sheet[0]))
    ctx.fillPath()
    ctx.restoreGState()
    fillVertical(sheetPath, gradient(palette.sheet), top: 0.79, bottom: 0.17)

    // Ruled lines.
    ctx.saveGState()
    ctx.addPath(sheetPath)
    ctx.clip()
    for y in [0.58, 0.47, 0.36, 0.25] as [CGFloat] {
        ctx.setFillColor(color(palette.rule))
        ctx.fill(rect(0.18, y, 0.64, 0.007))
    }

    // MARK: Metal clip header across the top of the sheet
    let header = rect(0.18, 0.655, 0.64, 0.135)
    ctx.drawLinearGradient(gradient(palette.header),
                           start: CGPoint(x: header.midX, y: header.maxY),
                           end: CGPoint(x: header.midX, y: header.minY), options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(palette.headerEdge))
    ctx.fill(rect(0.18, 0.648, 0.64, 0.012))

    // Ring at the top.
    let ringCenter = point(0.5, 0.80)
    let ringRadius = 0.05 * u
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.004), blur: u * 0.01, color: color(0x000000, 0.3))
    ctx.addEllipse(in: CGRect(x: ringCenter.x - ringRadius, y: ringCenter.y - ringRadius,
                              width: ringRadius * 2, height: ringRadius * 2))
    ctx.setFillColor(color(palette.ringFill))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addEllipse(in: CGRect(x: ringCenter.x - ringRadius, y: ringCenter.y - ringRadius,
                              width: ringRadius * 2, height: ringRadius * 2))
    ctx.setStrokeColor(color(palette.ringStroke))
    ctx.setLineWidth(u * 0.008)
    ctx.strokePath()
    let hole = 0.02 * u
    ctx.addEllipse(in: CGRect(x: ringCenter.x - hole, y: ringCenter.y - hole, width: hole * 2, height: hole * 2))
    ctx.setFillColor(color(palette.ringHole))
    ctx.fillPath()

    // MARK: Eyes — glossy dark capsules with a cartoon highlight
    for x in [0.37, 0.63] as [CGFloat] {
        let eye = rect(x - 0.05, 0.33, 0.10, 0.215)
        let eyePath = CGPath(roundedRect: eye, cornerWidth: eye.width / 2, cornerHeight: eye.width / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.006), blur: u * 0.012, color: color(0x000000, 0.25))
        ctx.addPath(eyePath)
        ctx.setFillColor(color(palette.eyeBase))
        ctx.fillPath()
        ctx.restoreGState()
        fillVertical(eyePath, gradient(palette.eye),
                     top: (eye.maxY - canvas.minY) / u, bottom: (eye.minY - canvas.minY) / u)
        // Highlight dot, upper left.
        let dot = 0.022 * u
        let dotCenter = CGPoint(x: eye.minX + eye.width * 0.36, y: eye.maxY - eye.width * 0.42)
        ctx.addEllipse(in: CGRect(x: dotCenter.x - dot, y: dotCenter.y - dot, width: dot * 2, height: dot * 2))
        ctx.setFillColor(color(palette.eyeHighlight, 0.92))
        ctx.fillPath()
    }

    // MARK: Wi-Fi badge — white disc with a purple signal, overlapping the bottom-right corner
    let badgeCenter = point(0.76, 0.22)
    let badgeRadius = 0.135 * u
    let badgeRect = CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                           width: badgeRadius * 2, height: badgeRadius * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.008), blur: u * 0.025, color: color(palette.badgeShadow, 0.45))
    ctx.addEllipse(in: badgeRect)
    ctx.setFillColor(color(palette.badge[0]))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: badgeRect)
    ctx.clip()
    ctx.drawLinearGradient(gradient(palette.badge), start: CGPoint(x: badgeCenter.x, y: badgeRect.maxY),
                           end: CGPoint(x: badgeCenter.x, y: badgeRect.minY), options: [])
    ctx.restoreGState()

    // Three arcs and a dot, fanning upward.
    let signalOrigin = CGPoint(x: badgeCenter.x, y: badgeCenter.y - u * 0.068)
    ctx.setStrokeColor(color(palette.signal))
    ctx.setLineCap(.round)
    ctx.setLineWidth(u * 0.02)
    for radius in [0.045, 0.082, 0.119] as [CGFloat] {
        ctx.addArc(center: signalOrigin, radius: radius * u, startAngle: .pi * 0.27, endAngle: .pi * 0.73, clockwise: false)
        ctx.strokePath()
    }
    let dot = 0.017 * u
    ctx.addEllipse(in: CGRect(x: signalOrigin.x - dot, y: signalOrigin.y - dot, width: dot * 2, height: dot * 2))
    ctx.setFillColor(color(palette.signal))
    ctx.fillPath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "failed to write \(path)")
    print("wrote \(path)")
}

write(render(size: 1024, mac: false), to: "iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
write(render(size: 1024, mac: false, palette: .dark), to: "iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png")
write(render(size: 1024, mac: true), to: "Mac/Assets.xcassets/AppIcon.appiconset/mac-1024.png")
