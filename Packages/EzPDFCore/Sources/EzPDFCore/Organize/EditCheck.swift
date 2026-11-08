import Foundation
import AppKit
import PDFKit
import CoreText

/// How a text edit is set on the page so it reads like the rest of the document.
///
/// - Same type: the new words use the document's own font, size and color (never shrunk). If that
///   font isn't on this Mac, the closest system face is used and the caller is told.
/// - Tidy: no stray spaces at the ends when the old text had none; no "$" or "(" the page already has
///   just before it, no "." "," ";" ":" "!" "?" ")" "%" it already has just after it; no double spaces.
/// - Room: the rest of the line moves over (or back) after the new words. Words that no longer fit
///   carry to the next line of the same paragraph, line by line, stopping at the first line that
///   fits again; the paragraph may grow into blank space below it (up to 3 lines), never over other
///   text. If it can't fit, nothing is changed and the caller is told why.
enum EditCheck {
    struct Plan {
        var overlays: [EditOps.Overlay]
        var notes: [String]
        var newWords: String
    }

    struct TooLong: Error { var message: String }

    // MARK: Tidy

    /// The characters just before and just after a match on its page.
    static func neighbors(_ sel: PDFSelection) -> (before: Character?, after: Character?) {
        let inner = sel.string ?? ""
        func side(_ atStart: Bool) -> Character? {
            guard let wider = sel.copy() as? PDFSelection else { return nil }
            if atStart { wider.extend(atStart: 1) } else { wider.extend(atEnd: 1) }
            let s = wider.string ?? ""
            guard s.count > inner.count else { return nil }
            return atStart ? s.first : s.last
        }
        return (side(true), side(false))
    }

    /// The replacement adjusted to its surroundings, with a note for each change made.
    static func tidy(_ replacement: String, original: String, before: Character?, after: Character?) -> (text: String, notes: [String]) {
        var t = replacement
        var notes: [String] = []
        if original.first.map({ !$0.isWhitespace }) ?? true {
            while t.first?.isWhitespace == true { t.removeFirst() }
        }
        if original.last.map({ !$0.isWhitespace }) ?? true {
            while t.last?.isWhitespace == true { t.removeLast() }
        }
        if t.contains("  ") {
            t = t.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        }
        if let b = before, "$€£₹¥(".contains(b), t.first == b {
            t.removeFirst()
            while t.first == " " { t.removeFirst() }
            notes.append("Left out the “\(b)” at the start; the page already has it before the change.")
        }
        if let a = after, ".,;:!?)%".contains(a), t.last == a {
            t.removeLast()
            notes.append("Left out the “\(a)” at the end; the page already has it after the change.")
        }
        let letters = original.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase), t.contains(where: \.isLowercase) {
            notes.append("The old text was in capitals and the new text isn't; say if it should be.")
        }
        return (t, notes)
    }

    // MARK: Planning

    static func width(_ s: String, _ font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    /// One line of the page's text after the match: what it says, where it is, its type.
    struct Line { var text: String; var rect: CGRect; var font: NSFont }

    /// The lines of the paragraph that follow `sel` on its page (same left edge, same type, regular
    /// spacing), and the text on the match's last line after it.
    static func following(_ sel: PDFSelection, on page: PDFPage, space: EditOps.PageSpace, font: NSFont, columnRight: CGFloat) -> (rest: Line?, lines: [Line]) {
        let match = sel.range(at: 0, on: page)
        guard match.location != NSNotFound, let str = page.string else { return (nil, []) }
        let total = (str as NSString).length
        let start = match.location + match.length
        guard start < total, let after = page.selection(for: NSRange(location: start, length: min(4000, total - start))) else { return (nil, []) }
        let byLine = after.selectionsByLine()
        func line(_ s: PDFSelection) -> Line? {
            var text = s.string ?? ""
            while text.last?.isNewline == true || text.last == " " { text.removeLast() }
            let style = EditOps.textStyle(of: s)
            return Line(text: text, rect: space.topLeft(s.bounds(for: page)), font: style.font)
        }
        let matchLine = space.topLeft(sel.selectionsByLine().last?.bounds(for: page) ?? sel.bounds(for: page))
        var rest: Line?
        var lines: [Line] = []
        // A line ends its paragraph when it stops short of the right edge (a line break, not a wrap).
        func ranToEdge(_ r: CGRect, left: CGFloat) -> Bool { r.maxX >= columnRight - max(36, (columnRight - left) * 0.18) }
        var previousEnd = matchLine
        for (i, s) in byLine.enumerated() {
            guard let l = line(s) else { break }
            if i == 0, abs(l.rect.midY - matchLine.midY) < matchLine.height * 0.6 {
                if l.text.contains(where: { !$0.isWhitespace }) { rest = l; previousEnd = matchLine.union(l.rect) }
                continue
            }
            guard ranToEdge(previousEnd, left: lines.first?.rect.minX ?? previousEnd.minX) else { break }
            // The paragraph goes on while lines keep its type, left edge and spacing.
            guard !l.text.trimmingCharacters(in: .whitespaces).isEmpty,
                  l.font.fontName == font.fontName, abs(l.font.pointSize - font.pointSize) < 0.6 else { break }
            let previous = lines.last?.rect ?? matchLine
            let gap = l.rect.minY - previous.minY
            guard gap > 0, gap < max(previous.height, l.rect.height) * 1.9 else { break }
            if let firstBelow = lines.first, abs(l.rect.minX - firstBelow.rect.minX) > 4 { break }
            if let last = lines.last, abs(gap - (last.rect.minY - (lines.dropLast().last?.rect ?? matchLine).minY)) > 3 { break }
            lines.append(l)
            previousEnd = l.rect
            if lines.count >= 40 { break }
        }
        return (rest, lines)
    }

    /// Lays out the replacement: in the match's place, moving the rest of the line and carrying
    /// overflow down the paragraph. Throws `TooLong` when it can't fit.
    static func plan(_ sel: PDFSelection, on page: PDFPage, replacement: String, words: [TextFragment]) throws -> Plan {
        let space = EditOps.PageSpace(page)
        let old = sel.string ?? ""
        let (before, after) = neighbors(sel)
        var (text, notes) = tidy(replacement, original: old, before: before, after: after)
        let style = EditOps.textStyle(of: sel)
        let font = style.font
        if let substitute = style.substitutedFor {
            notes.append("The document's font (\(substitute)) isn't on this Mac, so the closest one, \(font.displayName ?? font.fontName), was used.")
        }
        let matchLines = sel.selectionsByLine().map { space.topLeft($0.bounds(for: page)) }.filter { !$0.isEmpty }
        guard let first = matchLines.first else { throw TooLong(message: "Couldn't find where “\(old)” is on the page.") }
        var overlays: [EditOps.Overlay] = []
        func cover(_ r: CGRect) {
            let bg = EditOps.backgroundColor(page, around: space.pageRect(r)) ?? .white
            overlays.append(.fill(r.insetBy(dx: -1, dy: -1), bg))
        }
        matchLines.forEach(cover)
        let matchLineRect = matchLines.last ?? first
        let lineLeft = words.filter { abs($0.rect.midY - first.midY) < first.height * 0.6 }.map(\.rect.minX).min() ?? first.minX
        let columnGuess = words.filter { $0.rect.minX >= lineLeft - 2 && $0.rect.minX < max(matchLineRect.maxX, first.maxX) + 1 }.map(\.rect.maxX).max() ?? matchLineRect.maxX
        let (rest, below) = following(sel, on: page, space: space, font: font, columnRight: columnGuess)
        if text.isEmpty {
            if let b = before, let a = after, b.isWhitespace, a.isWhitespace {
                notes.append("Erased; the space where it was stays, since a PDF line doesn't close up.")
            }
            return Plan(overlays: overlays, notes: notes, newWords: "")
        }

        // The paragraph's edges. Left: where its following lines start (or this line's text column).
        // Right: as far as text in the same column reaches, at least a margin as wide as the left one,
        // never past the page margin or into text further right (another column).
        let lineRect = rest.map { first.union($0.rect) } ?? first
        let left = below.first?.rect.minX ?? min(first.minX, words.filter { abs($0.rect.midY - lineRect.midY) < lineRect.height * 0.6 }.map(\.rect.minX).min() ?? first.minX)
        let paragraphEnd = max(lineRect.maxX, below.map(\.rect.maxX).max() ?? 0)
        let columnRight = words.filter { $0.rect.minX >= left - 2 && $0.rect.minX < paragraphEnd }.map(\.rect.maxX).max() ?? paragraphEnd
        // A paragraph of several lines keeps its own right edge; a single line may use the column's
        // width (or a margin as wide as the left one).
        var right = below.isEmpty ? min(space.bounds.maxX - 18, max(paragraphEnd, columnRight, space.bounds.width - left))
                                  : max(paragraphEnd, below.dropLast().map(\.rect.maxX).max() ?? paragraphEnd)
        let bandBottom = (below.last?.rect ?? matchLines.last ?? first).maxY + 3 * max(first.height, 12)
        if let obstacle = words.filter({ $0.rect.minX > paragraphEnd + 1 && $0.rect.maxY > first.minY - 2 && $0.rect.minY < bandBottom })
            .map(\.rect.minX).min() {
            right = min(right, max(paragraphEnd, obstacle - 6))
        }
        let spacing = below.first.map { $0.rect.minY - (matchLines.last ?? first).minY } ?? ceil((font.ascender - font.descender + font.leading) * 1.2)

        // Slots to write lines into: the match's first line from where it starts, then each further
        // line of the match and of the paragraph from the left edge.
        struct Slot { var x: CGFloat; var top: CGRect; var original: String? }
        var slots: [Slot] = [Slot(x: first.minX, top: first, original: nil)]
        for r in matchLines.dropFirst() { slots.append(Slot(x: left, top: r, original: nil)) }
        for l in below { slots.append(Slot(x: left, top: l.rect, original: l.text)) }
        // Blank room under the paragraph for up to 3 more lines, not over other text or the margin.
        let lastRect = below.last?.rect ?? matchLines.last ?? first
        let nextTextTop = words.filter { $0.rect.minY > lastRect.maxY + 1 && $0.rect.maxX > left && $0.rect.minX < right }.map(\.rect.minY).min()
            ?? space.bounds.maxY - 36
        var extra = 0
        while extra < 3, lastRect.minY + CGFloat(extra + 1) * spacing + lastRect.height <= min(nextTextTop - 2, space.bounds.maxY - 36) { extra += 1 }
        for k in 0..<extra {
            let r = lastRect.offsetBy(dx: 0, dy: CGFloat(k + 1) * spacing)
            slots.append(Slot(x: left, top: CGRect(x: left, y: r.minY, width: right - left, height: r.height), original: nil))
        }

        // Fill line by line: what fits stays on the line, the rest carries to the next; stop as
        // soon as nothing carries over (lines further down keep their own text and look).
        var carry = text + (rest?.text ?? "")
        var written: [(text: String, slot: Slot)] = []
        var i = 0
        while true {
            guard i < slots.count else {
                throw TooLong(message: "“\(text)” needs more room than its paragraph has, and the type stays the same size, so nothing was changed. Shorten it, or replace a whole sentence.")
            }
            let slot = slots[i]
            if i >= matchLines.count, let original = slot.original {
                // A paragraph line below takes the carried words in front of its own. A word broken
                // with a hyphen at the end of the carry joins up again.
                if carry.isEmpty { carry = original }
                else if carry.hasSuffix("-"), carry.dropLast().last?.isLetter == true { carry = String(carry.dropLast()) + original }
                else { carry += " " + original }
            }
            let (fits, spill) = split(carry, font: font, width: right - slot.x)
            guard !fits.isEmpty || carry.isEmpty else {
                throw TooLong(message: "A word in “\(text)” is wider than the line, so nothing was changed.")
            }
            written.append((fits, slot))
            carry = spill
            i += 1
            // Done once nothing carries over and every line the old text used has been written;
            // the paragraph's later lines keep their own text and look.
            if carry.isEmpty && i >= matchLines.count { break }
        }
        // Paint over what moves, then write it.
        if let rest { cover(rest.rect) }
        for w in written where w.slot.original != nil { cover(w.slot.top) }
        for (line, slot) in written.map({ ($0.text, $0.slot) }) where !line.isEmpty {
            var box = EditOps.textBox(for: line, font: font, firstLine: CGRect(x: slot.x, y: slot.top.minY, width: right - slot.x, height: slot.top.height),
                                      minWidth: right - slot.x, page: space.bounds)
            box.size.width = right - slot.x + 2
            overlays.append(.text(line, rect: box, font: font, color: style.color, alignment: .left))
        }
        let moved = written.filter { $0.slot.original != nil }.count
        if rest != nil || moved > 0 {
            notes.append(moved > 0 ? "Carried the following words onto the next \(moved == 1 ? "line" : "\(moved) lines") of the paragraph, in the same type."
                                   : "Moved the rest of the line to sit right after the new words, in the same type.")
        }
        return Plan(overlays: overlays, notes: notes, newWords: text)
    }

    /// Splits text at the last word that fits `width` in `font` (everything if it all fits).
    static func split(_ s: String, font: NSFont, width limit: CGFloat) -> (fits: String, spill: String) {
        if width(s, font) <= limit { return (s, "") }
        var cut = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == " " {
                if width(String(s[..<i]), font) > limit { break }
                cut = i
            }
            i = s.index(after: i)
        }
        guard cut > s.startIndex else { return ("", s) }
        return (String(s[..<cut]), String(s[s.index(after: cut)...]))
    }

}
