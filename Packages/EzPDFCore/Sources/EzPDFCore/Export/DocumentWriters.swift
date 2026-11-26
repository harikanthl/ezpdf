import Foundation

/// Writes a `StructuredText.Document` as Markdown, plain text or a Word document.
enum DocumentWriters {
    typealias Block = StructuredText.Block
    typealias Run = StructuredText.Run

    // MARK: Markdown

    /// `figurePath(n)` is the relative path figure n (1-based) is saved at.
    static func markdown(_ doc: StructuredText.Document, figurePath: (Int) -> String) -> String {
        var parts: [String] = []
        var figure = 0
        var lastWasList = false
        for block in doc.blocks {
            var text: String
            var isList = false
            switch block {
            case .heading(let level, let t):
                text = String(repeating: "#", count: min(max(level, 1), 6)) + " " + escape(t)
            case .paragraph(let runs):
                text = inline(runs)
                text = escapeBlockStart(text)
            case .listItem(let marker, let runs):
                switch marker {
                case .bullet: text = "- " + inline(runs); isList = true
                case .number(let n): text = "\(n). " + inline(runs); isList = true
                // Markdown has no lettered lists: each item stays a line of its own, lettered.
                case .letter(let n): text = "\(letter(n)). " + inline(runs)
                }
            case .table(let rows):
                text = table(rows)
            case .figure:
                figure += 1
                text = "![Figure \(figure)](\(figurePath(figure).replacingOccurrences(of: " ", with: "%20")))"
            }
            // List items sit together; everything else gets a blank line around it.
            if isList && lastWasList, let last = parts.popLast() { parts.append(last + "\n" + text) } else { parts.append(text) }
            lastWasList = isList
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// A paragraph that starts like a heading, quote or list would turn into one: "# x", "> x",
    /// "- x", "+ x" get a backslash in front; "12. x" gets it before the dot ("\\12." isn't an
    /// escape in CommonMark, the backslash would show).
    static func escapeBlockStart(_ text: String) -> String {
        if let r = text.range(of: #"^\d{1,9}(?=[.)](\s|$))"#, options: .regularExpression) {
            return String(text[r]) + "\\" + text[r.upperBound...]
        }
        if let f = text.first, "#>".contains(f) { return "\\" + text }
        if text.range(of: #"^[-+](\s|$)"#, options: .regularExpression) != nil { return "\\" + text }
        return text
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\`*_[]<>|".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Runs with **bold** and *italic*; spaces stay outside the markers (Markdown needs that).
    static func inline(_ runs: [Run]) -> String {
        runs.map { r in
            let body = escape(r.text)
            guard r.bold || r.italic else { return body }
            let core = body.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return body }
            let lead = String(body.prefix { $0 == " " }), trail = String(body.reversed().prefix { $0 == " " })
            let mark = r.bold && r.italic ? "***" : r.bold ? "**" : "*"
            return lead + mark + core + mark + trail
        }.joined()
    }

    static func table(_ rows: [[String]]) -> String {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return "" }
        func row(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: width - cells.count)
            return "| " + padded.map { escape($0).replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
        }
        var lines = [row(rows[0]), "|" + Array(repeating: " --- |", count: width).joined()]
        lines += rows.dropFirst().map(row)
        return lines.joined(separator: "\n")
    }

    // MARK: Plain text

    static func plainText(_ doc: StructuredText.Document) -> String {
        var parts: [String] = []
        var lastWasList = false
        for block in doc.blocks {
            var text: String
            var isList = false
            switch block {
            case .heading(_, let t): text = t
            case .paragraph(let runs): text = runs.map(\.text).joined()
            case .listItem(let marker, let runs):
                switch marker {
                case .bullet: text = "• "
                case .number(let n): text = "\(n). "
                case .letter(let n): text = "\(letter(n)). "
                }
                text += runs.map(\.text).joined()
                isList = true
            case .table(let rows): text = rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            case .figure: continue
            }
            if isList && lastWasList, let last = parts.popLast() { parts.append(last + "\n" + text) } else { parts.append(text) }
            lastWasList = isList
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    // MARK: Word

    /// A .docx: real Heading 1–4 styles (so Word's navigation pane and table of contents work),
    /// bulleted and numbered lists, tables with borders, and figures as pictures.
    static func docx(_ doc: StructuredText.Document) -> Data {
        var body = ""
        var media: [(name: String, data: Data)] = []
        // One numbering instance per run of numbered or lettered items, so each list starts afresh
        // (abstract list 1 counts 1, 2, 3; abstract list 2 counts a, b, c).
        var numbering: [(abstract: Int, start: Int)] = []
        var lastList: StructuredText.ListMarker?

        // Text width: the page less one-inch margins (twips; 20 per point).
        let pageW = Int(doc.pageSize.width * 20), pageH = Int(doc.pageSize.height * 20)
        let margin = 1440
        let textWidthPt = max(144, doc.pageSize.width - 144)

        for block in doc.blocks {
            if case .listItem = block {} else { lastList = nil }
            switch block {
            case .heading(let level, let text):
                body += "<w:p><w:pPr><w:pStyle w:val=\"Heading\(min(max(level, 1), 4))\"/></w:pPr>\(run(Run(text: text)))</w:p>"
            case .paragraph(let runs):
                body += "<w:p>\(runs.map(run).joined())</w:p>"
            case .listItem(let marker, let runs):
                let numID: Int
                switch marker {
                case .bullet:
                    numID = 1                                // the bullet list
                    lastList = .bullet
                case .number(let n), .letter(let n):
                    let abstract = { if case .letter = marker { return 2 } else { return 1 } }()
                    let sameKind: Bool = {
                        switch (lastList, marker) {
                        case (.number?, .number), (.letter?, .letter): return true
                        default: return false
                        }
                    }()
                    if !sameKind { numbering.append((abstract, n)) }
                    lastList = marker
                    numID = numbering.count + 1
                }
                body += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(numID)\"/></w:numPr></w:pPr>\(runs.map(run).joined())</w:p>"
            case .table(let rows):
                let cols = rows.map(\.count).max() ?? 0
                guard cols > 0 else { continue }
                let colW = (pageW - 2 * margin) / cols
                body += "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblLook w:val=\"04A0\" w:firstRow=\"1\"/></w:tblPr><w:tblGrid>"
                body += String(repeating: "<w:gridCol w:w=\"\(colW)\"/>", count: cols) + "</w:tblGrid>"
                for (r, cells) in rows.enumerated() {
                    body += r == 0 ? "<w:tr><w:trPr><w:tblHeader/></w:trPr>" : "<w:tr>"
                    for c in 0..<cols {
                        let text = c < cells.count ? cells[c] : ""
                        body += "<w:tc><w:tcPr><w:tcW w:w=\"\(colW)\" w:type=\"dxa\"/></w:tcPr><w:p>\(text.isEmpty ? "" : run(Run(text: text, bold: r == 0)))</w:p></w:tc>"
                    }
                    body += "</w:tr>"
                }
                // Word needs a paragraph between two tables (and after the last one).
                body += "</w:tbl><w:p/>"
            case .figure(let f):
                media.append(("image\(media.count + 1).jpeg", f.jpeg))
                let k = media.count
                let scale = min(1, textWidthPt / max(f.size.width, 1))
                let cx = Int(f.size.width * scale * 12700), cy = Int(f.size.height * scale * 12700)
                body += """
                <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
                <wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(k)" name="Figure \(k)"/>\
                <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
                <pic:nvPicPr><pic:cNvPr id="\(k)" name="image\(k).jpeg"/><pic:cNvPicPr/></pic:nvPicPr>\
                <pic:blipFill><a:blip r:embed="rIdImg\(k)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
                </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                """
            }
        }
        if body.isEmpty { body = "<w:p/>" }
        body += "<w:sectPr><w:pgSz w:w=\"\(pageW)\" w:h=\"\(pageH)\"/><w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        </Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        </Relationships>
        """)
        zip.add("docProps/core.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">\
        <dc:title>\(xml(doc.title ?? ""))</dc:title></cp:coreProperties>
        """)
        zip.add("word/_rels/document.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
        \(media.enumerated().map { "<Relationship Id=\"rIdImg\($0.offset + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\($0.element.name)\"/>" }.joined())\
        </Relationships>
        """)
        zip.add("word/document.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """)
        zip.add("word/styles.xml", styles)
        zip.add("word/numbering.xml", numberingXML(starts: numbering))
        for m in media { zip.add("word/media/\(m.name)", m.data, compress: false) }
        return zip.finish()
    }

    static func run(_ r: Run) -> String {
        var props = ""
        if r.bold { props += "<w:b/>" }
        if r.italic { props += "<w:i/>" }
        return "<w:r>\(props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>")<w:t xml:space=\"preserve\">\(xml(r.text))</w:t></w:r>"
    }

    /// XML text: escaped, and without the control characters XML can't hold.
    static func xml(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                let v = u.value
                if v == 9 || v == 10 || v == 13 || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000 {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out
    }

    /// "a" for 1, … "z" for 26, then "aa".
    static func letter(_ n: Int) -> String {
        let k = max(n, 1) - 1
        let ch = String(UnicodeScalar(UInt8(97 + k % 26)))
        return String(repeating: ch, count: k / 26 + 1)
    }

    static func numberingXML(starts: [(abstract: Int, start: Int)]) -> String {
        var nums = "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        for (k, list) in starts.enumerated() {
            nums += "<w:num w:numId=\"\(k + 2)\"><w:abstractNumId w:val=\"\(list.abstract)\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"\(list.start)\"/></w:lvlOverride></w:num>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="singleLevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/>\
        <w:lvlText w:val="•"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
        <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="singleLevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/>\
        <w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
        <w:abstractNum w:abstractNumId="2"><w:multiLevelType w:val="singleLevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/>\
        <w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
        \(nums)</w:numbering>
        """
    }

    static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="280" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/><w:i/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/>\
    <w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>\
    <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/>\
    <w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
    <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>\
    <w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/><w:left w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/>\
    <w:bottom w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/><w:right w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/>\
    <w:insideH w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="A6A6A6"/></w:tblBorders></w:tblPr></w:style>\
    </w:styles>
    """
}
