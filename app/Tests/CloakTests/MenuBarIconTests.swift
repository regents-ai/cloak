import AppKit
import CloakSupervisor
@testable import RegentsCloak
import Testing

/// The menu bar icon draws the master crown's 13 blocks on its grid, and its
/// badge hides none of them, in every state.
struct MenuBarIconTests {
    @Test(arguments: [
        Phase.paused, .preparing(.run), .running, .ready, .stopping(.paused), .needsAttention(.workerStopped),
    ])
    func theCrownIsTheMastersThirteenBlocks(phase: Phase) throws {
        let image = MenuBarIcon.image(phase)
        #expect(image.isTemplate)
        // At 2x, two pixels a point.
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * 2, pixelsHigh: Int(image.size.height) * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        // The master's grid of 4-point cells, top row first: three merlons
        // over two full rows.
        let master = ["X.X.X", "XXXXX", "XXXXX"]
        for (row, cells) in master.enumerated() {
            for (column, cell) in cells.enumerated() {
                // A point a point inside the cell's top leading corner, clear
                // of the gaps between blocks and of the badge.
                let pixel = try #require(bitmap.colorAt(x: 2 * (4 * column + 1), y: 2 * (4 * row + 1)))
                #expect(pixel.alphaComponent == (cell == "X" ? 1 : 0), "row \(row), column \(column)")
            }
        }
    }
}
