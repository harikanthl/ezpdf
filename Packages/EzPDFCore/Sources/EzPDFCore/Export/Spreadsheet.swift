import Foundation

/// CSV (RFC 4180) and XLSX (Office Open XML, written directly) exporters.
public enum Spreadsheet {
    public struct Sheet {
        public var name: String
        public var rows: [[String]]
        public init(name: String, rows: [[String]]) { self.name = name; self.rows = rows }
    }

    public static func csv(_ rows: [[String]]) -> Data {
        let text = rows.map { row in
            row.map { cell -> String in
                // Leading = + - @ would run as formulas when opened in Excel; neutralize them.
                var c = cell
                if let f = c.first, "=+@".contains(f) || (f == "-" && Double(c) == nil) { c = "'" + c }
                if c.contains(",") || c.contains("\"") || c.contains("\n") {
                    return "\"" + c.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return c
            }.joined(separator: ",")
        }.joined(separator: "\r\n")
        return Data(("\u{FEFF}" + text + "\r\n").utf8)     // BOM so Excel reads UTF-8
    }

    public static func xlsx(_ sheets: [Sheet]) -> Data {
        var zip = ZipWriter()
        let sheets = sheets.isEmpty ? [Sheet(name: "Sheet1", rows: [])] : sheets
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        \(sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())
        </Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """)
        var usedNames = Set<String>()
        let names = sheets.map { s -> String in
            var n = String(s.name.replacingOccurrences(of: "[\\[\\]:*?/\\\\]", with: " ", options: .regularExpression).prefix(31))
            if n.isEmpty { n = "Sheet" }
            var candidate = n; var k = 2
            while usedNames.contains(candidate.lowercased()) { candidate = String(n.prefix(28)) + " \(k)"; k += 1 }
            usedNames.insert(candidate.lowercased())
            return candidate
        }
        zip.add("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>\(names.enumerated().map { "<sheet name=\"\(esc($0.element))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined())</sheets>
        </workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())
        <Relationship Id="rId\(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """)
        // Style 1: bold header. Style 2: number with 2 decimals.
        zip.add("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border/></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>
        </styleSheet>
        """)
        for (i, sheet) in sheets.enumerated() { zip.add("xl/worksheets/sheet\(i + 1).xml", worksheet(sheet.rows)) }
        return zip.finish()
    }

    static func worksheet(_ rows: [[String]]) -> String {
        let colCount = rows.map(\.count).max() ?? 0
        let widths = (0..<colCount).map { c in min(60, max(8, rows.prefix(500).map { c < $0.count ? $0[c].count : 0 }.max() ?? 8) + 2) }
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        """
        if rows.count > 1 { xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>" }
        if colCount > 0 { xml += "<cols>" + widths.enumerated().map { "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\($0.element)\" customWidth=\"1\"/>" }.joined() + "</cols>" }
        xml += "<sheetData>"
        for (r, row) in rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = column(c) + String(r + 1)
                if r > 0, value.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil, value.count < 16 {
                    let style = value.contains(".") ? " s=\"2\"" : ""
                    xml += "<c r=\"\(ref)\"\(style)><v>\(value)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"\(r == 0 ? " s=\"1\"" : "")><is><t xml:space=\"preserve\">\(esc(value))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    static func column(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let m = (n - 1) % 26; s = String(UnicodeScalar(65 + m)!) + s; n = (n - 1) / 26 }
        return s
    }

    static func esc(_ s: String) -> String {
        let cleaned = s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" }
        return String(String.UnicodeScalarView(cleaned))
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
