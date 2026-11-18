import CoreImage
import Foundation
@testable import RegentsCloak
import Testing

/// The wallet sheet's QR code reads back as exactly the address, inside its
/// white quiet zone.
struct QRCodeTests {
    @Test func theCodeReadsBackAsTheAddress() throws {
        // Made up, in an address's shape.
        let address = "0x1234567890abcdef1234567890ABCDEF12345678"
        let code = try #require(QRCode.image(for: address))
        let detector = try #require(
            CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let read = detector.features(in: CIImage(cgImage: code)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(read == [address])

        // One grey byte per pixel; the four pixels, one per module, at each
        // edge are white.
        #expect(code.bitsPerPixel == 8)
        let pixels = try #require(code.dataProvider?.data as Data?)
        let edge = (0..<code.height).flatMap { y in
            (0..<code.width).filter { x in min(x, y, code.width - 1 - x, code.height - 1 - y) < 4 }
                .map { x in pixels[y * code.bytesPerRow + x] }
        }
        #expect(edge.allSatisfy { $0 == 255 })
    }
}
