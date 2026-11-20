// Draws the app's icon and the picture behind the install window, for
// app/art.sh, which packs them as app/AppIcon.icns and
// app/install-window.tiff. Both files are committed; run app/art.sh again
// only when the drawing changes.
//
// The icon is the Regents crown, block for block as the design system's
// logos/regents-crown-flat-dark.svg draws it, on that file's near-black, in
// macOS proportions: an 824-pixel tile on a 1024 canvas with the system's
// continuous corners and a soft shadow (Sean's "11. a", 20 November 2026).
//
//     swift app/art.swift <folder for the pictures>
import AppKit
import SwiftUI

// The master's blocks: 34 units square on a 36-unit pitch, from the corner
// of its first block.
let blocks: [(CGFloat, CGFloat)] = [
    (0, 0), (72, 0), (144, 0),
    (0, 36), (36, 36), (72, 36), (108, 36), (144, 36),
    (0, 72), (36, 72), (72, 72), (108, 72), (144, 72),
]

func grey(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

/// A canvas with its origin at the top left.
func canvas(_ width: Int, _ height: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    return context
}

func write(_ context: CGContext, _ path: String) {
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

/// The crown at 3 pixels a unit (blocks 102 on a pitch of 108), centred on
/// the tile.
func icon() -> CGContext {
    let context = canvas(1024, 1024)
    let tile = Path(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerRadius: 185.4, style: .continuous).cgPath
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: grey(0x000000, 0.30))
    context.addPath(tile)
    context.setFillColor(grey(0x0A0A0A))
    context.fillPath()
    context.restoreGState()
    // A faint edge, so the tile keeps its shape on a dark background. Half
    // of the line falls outside the clip.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.addPath(tile)
    context.setStrokeColor(grey(0xFFFFFF, 0.12))
    context.setLineWidth(6)
    context.strokePath()
    context.restoreGState()
    let unit: CGFloat = 3
    let x = 100 + (824 - 178 * unit) / 2, y = 100 + (824 - 106 * unit) / 2
    context.setFillColor(grey(0xF5F5F2))
    for block in blocks {
        context.fill(CGRect(x: x + block.0 * unit, y: y + block.1 * unit, width: 34 * unit, height: 34 * unit))
    }
    return context
}

/// The install window's picture, 640 by 400 points at `scale`: an arrow
/// from where the app sits (170, 180) to where Applications sits (470, 180),
/// as app/install-window.py places them, on the design system's near-white.
func installWindow(scale: CGFloat) -> CGContext {
    let context = canvas(Int(640 * scale), Int(400 * scale))
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(grey(0xF5F5F2))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
    context.setStrokeColor(grey(0x9A9A94))
    context.setLineWidth(4)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 288, y: 180))
    context.addLine(to: CGPoint(x: 352, y: 180))
    context.move(to: CGPoint(x: 336, y: 164))
    context.addLine(to: CGPoint(x: 352, y: 180))
    context.addLine(to: CGPoint(x: 336, y: 196))
    context.strokePath()
    return context
}

let out = CommandLine.arguments[1]
write(icon(), out + "/icon.png")
write(installWindow(scale: 1), out + "/install-window.png")
write(installWindow(scale: 2), out + "/install-window@2x.png")
