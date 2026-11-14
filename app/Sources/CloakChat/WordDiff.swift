import Foundation

/// The words the rewording took out of the original and the words it put
/// into the reworded text, by `CollectionDifference` over the words of each
/// (runs of anything but whitespace), as ranges of each text.
public struct WordDiff: Sendable, Equatable {
    /// In the original.
    public let removed: [NSRange]
    /// In the reworded text.
    public let added: [NSRange]

    public init(original: String, reworded: String) {
        let old = Self.words(original), new = Self.words(reworded)
        var removed = [NSRange](), added = [NSRange]()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _):
                removed.append(NSRange(old[offset].startIndex..<old[offset].endIndex, in: original))
            case .insert(let offset, _, _):
                added.append(NSRange(new[offset].startIndex..<new[offset].endIndex, in: reworded))
            }
        }
        self.removed = removed
        self.added = added
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }
}
