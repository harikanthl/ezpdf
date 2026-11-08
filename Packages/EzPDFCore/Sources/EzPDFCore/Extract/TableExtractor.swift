import Foundation

public struct ExtractedTable: Codable, Sendable {
    public var page: Int          // 1-based, first page of the table
    public var rows: [[String]]
}

/// Finds tables by column alignment: runs of lines with 2+ cells whose cells line up with
/// shared column gaps (works for drawn and borderless tables alike).
public enum TableExtractor {
    public static func tables(_ lines: [TextLine], minRows: Int = 3) -> [ExtractedTable] {
        var groups: [[TextLine]] = []
        var current: [TextLine] = []
        for line in lines {
            let tabular = line.cells.count >= 2
            if tabular, let last = current.last,
               line.page == last.page ? line.y - last.y < last.height * 3.2 : current.count >= minRows {
                current.append(line)
            } else if tabular {
                if current.count >= minRows { groups.append(current) }
                current = [line]
            } else {
                if current.count >= minRows { groups.append(current) }
                current = []
            }
        }
        if current.count >= minRows { groups.append(current) }
        return groups.compactMap(table)
    }

    static func table(_ lines: [TextLine]) -> ExtractedTable? {
        let columns = columnRanges(lines)
        guard columns.count >= 2 else { return nil }
        let rows: [[String]] = lines.map { line in
            var row = Array(repeating: "", count: columns.count)
            for cell in line.cells {
                let mid = cell.rect.midX
                let i = columns.firstIndex { $0.contains(mid) }
                    ?? columns.indices.min { abs(center(columns[$0]) - mid) < abs(center(columns[$1]) - mid) }!
                row[i] = row[i].isEmpty ? cell.text : row[i] + " " + cell.text
            }
            return row
        }
        return ExtractedTable(page: lines[0].page + 1, rows: rows)
    }

    static func center(_ r: ClosedRange<CGFloat>) -> CGFloat { (r.lowerBound + r.upperBound) / 2 }

    /// Column x-ranges from where cells overlap; positions covered by few lines count as gaps,
    /// so one long description that spans two columns doesn't merge them.
    static func columnRanges(_ lines: [TextLine]) -> [ClosedRange<CGFloat>] {
        let cells = lines.flatMap(\.cells).filter { $0.rect.minX.isFinite && $0.rect.maxX.isFinite }
        let minX = cells.map(\.rect.minX).min() ?? 0
        let maxX = cells.map(\.rect.maxX).max() ?? 0
        // A sane page is a few thousand points wide; anything else is a broken rect.
        guard maxX > minX, maxX - minX < 20_000 else { return [] }
        let width = Int(maxX - minX) + 1
        var coverage = [Int](repeating: 0, count: width)
        for line in lines {
            for cell in line.cells where cell.rect.minX.isFinite && cell.rect.maxX.isFinite {
                let a = Int(cell.rect.minX - minX), b = min(width - 1, Int(cell.rect.maxX - minX))
                if a <= b { for x in a...b { coverage[x] += 1 } }
            }
        }
        let threshold = max(1, lines.count / 8)
        var ranges: [ClosedRange<CGFloat>] = []
        var start: Int?
        for x in 0..<width {
            if coverage[x] >= threshold {
                if start == nil { start = x }
            } else if let s = start {
                ranges.append(CGFloat(s) + minX...CGFloat(x - 1) + minX); start = nil
            }
        }
        if let s = start { ranges.append(CGFloat(s) + minX...CGFloat(width - 1) + minX) }
        // Merge columns separated by tiny gaps (letter spacing noise).
        var merged: [ClosedRange<CGFloat>] = []
        for r in ranges {
            if let last = merged.last, r.lowerBound - last.upperBound < 3 {
                merged[merged.count - 1] = last.lowerBound...r.upperBound
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}
