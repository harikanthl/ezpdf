import Foundation

/// Chooses where pages break in a laid-out web page so no line of text, image, formula
/// or table row is cut in half, and headings don't sit alone at the bottom of a page.
/// Pure and deterministic: the web view reports boxes, this decides the cuts.
public enum Paginator {
    public struct Box: Equatable, Sendable {
        public enum Kind: Int, Sendable { case atomic = 0, line = 1, heading = 2 }
        public var top: Double
        public var bottom: Double
        public var kind: Kind
        public init(top: Double, bottom: Double, kind: Kind) {
            self.top = top; self.bottom = bottom; self.kind = kind
        }
    }

    /// Returns `[start, end)` ranges, one per page, covering `0..<contentHeight`.
    public static func slices(contentHeight: Double, pageHeight: Double, boxes: [Box]) -> [Range<Double>] {
        guard contentHeight > 0, pageHeight > 0 else { return [] }
        // Boxes sorted by top so straddler lookup is a short scan.
        let sorted = boxes.filter { $0.bottom > $0.top }.sorted { $0.top < $1.top }
        var result: [Range<Double>] = []
        var start = 0.0
        // A page must carry at least this much, so a giant image can't stall pagination.
        let minFill = pageHeight * 0.3

        while start < contentHeight - 0.5 {
            let target = start + pageHeight
            if target >= contentHeight {
                result.append(start..<contentHeight)
                break
            }
            var end = target
            // Pull the cut up above anything it would slice through. Repeat: moving the cut
            // can land it inside a neighbouring box (an image beside a line of text).
            for _ in 0..<8 {
                var moved = false
                for box in sorted {
                    if box.top >= end { break }
                    if box.bottom > end + 0.5, box.top > start + minFill, box.top < end {
                        end = box.top
                        moved = true
                    }
                }
                if !moved { break }
            }
            // Keep headings with the text that follows them.
            let keepZone = pageHeight * 0.12
            for box in sorted where box.kind == .heading {
                if box.top >= end { break }
                if box.top > start + minFill, box.bottom > end - keepZone {
                    end = min(end, box.top)
                }
            }
            if end <= start + 1 { end = target }    // nothing safe: hard cut rather than loop
            result.append(start..<end)
            start = end
        }
        return result
    }
}
