import Foundation

/// The agent-facing tool set: small (15) so models that load every tool into context (xAI does
/// without allowed_tools) stay cheap, and annotated so TopRelay can expose read-only ones first.
@MainActor
enum MCPTools {
    static let presetValues = PagePreset.allCases.map(\.rawValue)
    static let maxInlinePDF = 4 * 1024 * 1024

    static func doc(_ r: DocumentRecord) -> [String: Any] {
        var d: [String: Any] = ["id": r.id, "title": r.title, "kind": r.kind.rawValue, "pages": r.pageCount,
                                "bytes": r.byteCount, "has_epub": r.hasEPUB,
                                "created": ISO8601DateFormatter().string(from: r.createdAt)]
        if let u = r.sourceURL { d["source_url"] = u }
        if let f = r.sourceFileName { d["source_file"] = f }
        if let s = r.siteName { d["site"] = s }
        if let b = r.byline { d["byline"] = b }
        if let p = r.preset { d["preset"] = p }
        if let k = r.sentToKindleAt { d["sent_to_kindle"] = ISO8601DateFormatter().string(from: k) }
        return d
    }

    static func line(_ r: DocumentRecord) -> String {
        "“\(r.title)” — id \(r.id), \(r.pageCount) page\(r.pageCount == 1 ? "" : "s")\(r.hasEPUB ? ", PDF + EPUB" : "")"
    }

    static func all(_ ops: EzPDF) -> [MCPTool] {
        [
            MCPTool(name: "convert_url", title: "Make a PDF from a link",
                    description: "Turn a web page into a clean, readable PDF (and EPUB) in the ezpdf library. Article pages are cleaned up (no ads or menus) and laid out for the chosen device; math, code and charts are kept. Takes 10–60 s.",
                    schema: S.object([
                        "url": S.string("http(s) link to convert"),
                        "preset": S.string("Page size. kindle (default) suits e-readers; web keeps the site's look.", enum: presetValues),
                        "format": S.string("pdf, epub or both (default both)", enum: ["pdf", "epub", "both"]),
                        "title": S.string("Optional title to use instead of the page's"),
                    ], required: ["url"]),
                    readOnly: false, openWorld: true) { a in
                guard let url = URL(string: try a.need("url")), url.scheme?.hasPrefix("http") == true else { throw EzPDFError.invalidInput("Give an http(s) URL.") }
                let rec = try await ops.convert(url: url, preset: PagePreset.parse(a.str("preset")), format: OutputFormat.parse(a.str("format")),
                                                title: a.str("title"), source: .agent)
                let notes = ops.jobs.first { $0.documentID == rec.id }?.notes ?? []
                return ToolOutput(text: "Saved \(line(rec)).\(notes.isEmpty ? "" : " " + notes.joined(separator: " "))", structured: doc(rec))
            },

            MCPTool(name: "convert_file", title: "Make a PDF from a file",
                    description: "Convert files on this Mac (images, Word, RTF, Markdown, text, HTML, CSV, or a PDF to import) into one PDF in the library. Pass paths, or file bytes as base64 with a file name.",
                    schema: S.object([
                        "paths": S.strings("Absolute file paths on the Mac; several are combined in order"),
                        "content_base64": S.string("File bytes as base64 (alternative to paths, max 20 MB)"),
                        "file_name": S.string("File name with extension, required with content_base64"),
                        "preset": S.string("Page size", enum: presetValues),
                        "title": S.string("Optional title"),
                    ]),
                    readOnly: false) { a in
                let preset = PagePreset.parse(a.str("preset"))
                let rec: DocumentRecord
                if let b64 = a.str("content_base64") {
                    guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { throw EzPDFError.invalidInput("content_base64 isn't valid base64.") }
                    rec = try await ops.convert(data: data, fileName: try a.need("file_name"), preset: preset)
                } else {
                    let paths = (a["paths"] as? [String] ?? []).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    guard !paths.isEmpty else { throw EzPDFError.invalidInput("Give paths or content_base64.") }
                    rec = try await ops.convert(files: paths, preset: preset, title: a.str("title"), source: .agent)
                }
                return ToolOutput(text: "Saved \(line(rec)).", structured: doc(rec))
            },

            MCPTool(name: "list_documents", title: "List documents",
                    description: "List documents in the ezpdf library, newest first. Optionally filter by text in the title, site or file name, or by kind.",
                    schema: S.object([
                        "query": S.string("Text to match"),
                        "kind": S.string("web, file, statement, invoice, merged or imported", enum: ["web", "file", "statement", "invoice", "merged", "imported"]),
                        "limit": S.int("Max results (default 25)"),
                    ]),
                    readOnly: true, idempotent: true) { a in
                let docs = ops.list(query: a.str("query"), kind: a.str("kind").flatMap(DocumentRecord.Kind.init), limit: a.int("limit") ?? 25)
                let text = docs.isEmpty ? "No documents match." : docs.map { "• " + line($0) }.joined(separator: "\n")
                return ToolOutput(text: text, structured: ["documents": docs.map(doc)])
            },

            MCPTool(name: "get_document", title: "Document details",
                    description: "Details of one document: title, source, page count, and its table of contents with page numbers.",
                    schema: S.object(["id": S.string("Document id or title")], required: ["id"]),
                    readOnly: true, idempotent: true) { a in
                let rec = try ops.record(try a.need("id"))
                let outline = try ops.outline(rec.id)
                var d = doc(rec)
                d["outline"] = outline.prefix(200).map { ["title": $0.title, "page": $0.page, "level": $0.level] }
                let toc = outline.prefix(40).map { String(repeating: "  ", count: max(0, $0.level - 1)) + "\($0.title) — p\($0.page)" }.joined(separator: "\n")
                return ToolOutput(text: line(rec) + (toc.isEmpty ? "" : "\nContents:\n" + toc), structured: d)
            },

            MCPTool(name: "get_text", title: "Read text",
                    description: "The text of a document (or some pages), with page markers. Scanned pages are read with on-device OCR. Use pages like \"1-3,7\" to read in parts.",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "pages": S.string("Page range, e.g. 1-5 or 2,4,9-. Default all"),
                        "max_chars": S.int("Cap on characters returned (default 40000)"),
                    ], required: ["id"]),
                    readOnly: true, idempotent: true) { a in
                let r = try await ops.text(try a.need("id"), pages: a.str("pages"), maxChars: a.int("max_chars") ?? 40_000)
                let tail = r.truncated ? "\n\n[Truncated after page \(r.pages.last ?? 0). Ask for later pages with “pages”.]" : ""
                return ToolOutput(text: r.text + tail, structured: ["pages_returned": r.pages, "truncated": r.truncated])
            },

            MCPTool(name: "search_text", title: "Search",
                    description: "Find words in one document or across the whole library. Returns page numbers and snippets.",
                    schema: S.object([
                        "query": S.string("Words to find"),
                        "id": S.string("Limit to one document (id or title)"),
                        "limit": S.int("Max hits (default 30)"),
                    ], required: ["query"]),
                    readOnly: true, idempotent: true) { a in
                let hits = try ops.search(try a.need("query"), in: a.str("id"), limit: a.int("limit") ?? 30)
                let text = hits.isEmpty ? "No matches." : hits.map { "• \($0.title) p\($0.page): …\($0.snippet)…" }.joined(separator: "\n")
                return ToolOutput(text: text, structured: ["hits": hits.map { ["id": $0.id, "title": $0.title, "page": $0.page, "snippet": $0.snippet] }])
            },

            MCPTool(name: "extract_data", title: "Extract statement / invoice data",
                    description: "Pull structured data out of a PDF: bank or credit-card statement → transactions (checked against the running balance); invoice or receipt → vendor, number, dates, totals and line items; anything else → tables. Runs on the Mac (on-device Apple Intelligence when available). Optionally saves CSV or Excel to the Downloads folder.",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "kind": S.string("auto (default), statement, invoice or tables", enum: ["auto", "statement", "invoice", "tables"]),
                        "save_as": S.string("Also save a file: csv or xlsx", enum: ["csv", "xlsx", "json"]),
                        "max_rows": S.int("Rows to return inline (default 200)"),
                    ], required: ["id"]),
                    readOnly: true, idempotent: true) { a in
                let id = try a.need("id")
                let result = try await ops.extract(id, kind: ExtractKind.parse(a.str("kind")), source: .agent)
                var saved: URL?
                if let f = a.str("save_as").flatMap(EzPDF.DataFormat.init) { saved = try ops.saveExtraction(result, for: id, format: f) }
                return summarize(result, maxRows: a.int("max_rows") ?? 200, saved: saved)
            },

            MCPTool(name: "edit_pages", title: "Edit pages",
                    description: "Rotate, delete, move, duplicate pages or insert a blank page (changes the document; undo_last_edit reverts). extract and split make new documents and leave the original alone. Pages are 1-based ranges like \"2-4,7\".",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "action": S.string("What to do", enum: EzPDF.PageAction.allCases.map(\.rawValue)),
                        "pages": S.string("Pages to act on"),
                        "degrees": S.int("rotate: 90, 180 or 270 (default 90 clockwise)"),
                        "to": S.int("move: 1-based position the pages should start at"),
                        "every": S.int("split: pages per part"),
                        "start_pages": S.ints("split: 1-based pages where new parts begin"),
                    ], required: ["id", "action"]),
                    readOnly: false, destructive: true) { a in
                guard let action = a.str("action").flatMap(EzPDF.PageAction.init) else { throw EzPDFError.invalidInput("Unknown action.") }
                let r = try ops.pages(try a.need("id"), action: action, pages: a.str("pages"), degrees: a.int("degrees") ?? 90,
                                      to: a.int("to"), every: a.int("every"), startPages: a["start_pages"] as? [Int])
                let text = r.created.isEmpty ? "Done. \(line(r.document))." : "Created:\n" + r.created.map { "• " + line($0) }.joined(separator: "\n")
                return ToolOutput(text: text, structured: ["document": doc(r.document), "created": r.created.map(doc)])
            },

            MCPTool(name: "merge_documents", title: "Merge",
                    description: "Combine documents, in the order given, into a new document.",
                    schema: S.object(["ids": S.strings("Document ids or titles, in order"), "title": S.string("Title for the result")], required: ["ids"]),
                    readOnly: false) { a in
                let rec = try ops.merge(a["ids"] as? [String] ?? [], title: a.str("title"))
                return ToolOutput(text: "Merged into \(line(rec)).", structured: doc(rec))
            },

            MCPTool(name: "improve_pdf", title: "Compress, OCR, protect…",
                    description: "Whole-document changes: compress (smaller), compress_strong (much smaller, lower image quality), make_searchable (OCR scanned pages), protect (add a password), unlock (remove it), page_numbers, watermark.",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "action": S.string("What to do", enum: EzPDF.Optimization.allCases.map(\.rawValue)),
                        "password": S.string("protect / unlock: the password"),
                        "text": S.string("watermark: the text"),
                    ], required: ["id", "action"]),
                    readOnly: false, destructive: true) { a in
                guard let action = a.str("action").flatMap(EzPDF.Optimization.init) else { throw EzPDFError.invalidInput("Unknown action.") }
                let r = try await ops.optimize(try a.need("id"), action, password: a.str("password"), text: a.str("text"))
                let size = action == .compress || action == .compress_strong
                    ? (r.after < r.before ? " \(kb(r.before)) → \(kb(r.after))." : " It was already as small as this setting gets.") : ""
                return ToolOutput(text: "Done: \(action.rawValue) on “\(r.record.title)”.\(size)", structured: ["document": doc(r.record), "bytes_before": r.before, "bytes_after": r.after])
            },

            MCPTool(name: "annotate", title: "Highlight or add a note",
                    description: "Highlight every occurrence of some text, or add a sticky note to a page.",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "action": S.string("highlight or note", enum: ["highlight", "note"]),
                        "text": S.string("highlight: text to find; note: the note"),
                        "page": S.int("note: 1-based page"),
                        "pages": S.string("highlight: only these pages"),
                    ], required: ["id", "action", "text"]),
                    readOnly: false) { a in
                let id = try a.need("id"), text = try a.need("text")
                if a.str("action") == "note" {
                    let rec = try ops.addNote(id, page: a.int("page") ?? 1, text: text)
                    return ToolOutput(text: "Added a note to page \(a.int("page") ?? 1) of “\(rec.title)”.", structured: doc(rec))
                }
                let r = try ops.highlight(id, text: text, pages: a.str("pages"))
                return ToolOutput(text: "Highlighted \(r.count) place\(r.count == 1 ? "" : "s") in “\(r.record.title)”.", structured: doc(r.record))
            },

            MCPTool(name: "send_to_kindle", title: "Send to Kindle",
                    description: "Email a document to the user's Kindle (address set in ezpdf Settings). Uses the EPUB when there is one, since Kindle reflows it; otherwise the PDF.",
                    schema: S.object(["id": S.string("Document id or title"), "format": S.string("Force pdf or epub", enum: ["pdf", "epub"])], required: ["id"]),
                    readOnly: false, openWorld: true) { a in
                let r = try ops.sendToKindle(try a.need("id"), format: a.str("format").flatMap(EzPDF.ExportFormat.init))
                return ToolOutput(text: "Sent “\(r.record.title)” as \(r.format.rawValue.uppercased()) to \(r.address). It usually appears on the Kindle within a few minutes.", structured: doc(r.record))
            },

            MCPTool(name: "export_file", title: "Save a copy",
                    description: "Save a copy of the PDF or EPUB to a folder on the Mac (default Downloads) and return its path.",
                    schema: S.object(["id": S.string("Document id or title"), "format": S.string("pdf (default) or epub", enum: ["pdf", "epub"]),
                                      "folder": S.string("Absolute folder path")], required: ["id"]),
                    readOnly: false) { a in
                let url = try ops.export(try a.need("id"), format: a.str("format").flatMap(EzPDF.ExportFormat.init) ?? .pdf,
                                         folder: a.str("folder").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
                return ToolOutput(text: "Saved to \(url.path)", structured: ["path": url.path])
            },

            MCPTool(name: "get_pdf", title: "Get the PDF file",
                    description: "Return the PDF itself (embedded, base64) so you can read or attach it. Limited to 4 MB; use pages to send part of a large document, or export_file to save it on the Mac.",
                    schema: S.object(["id": S.string("Document id or title"), "pages": S.string("Only these pages, e.g. 1-10")], required: ["id"]),
                    readOnly: true, idempotent: true) { a in
                let id = try a.need("id")
                let rec = try ops.record(id)
                let data = try ops.pdfData(id, pages: a.str("pages"))
                guard data.count <= maxInlinePDF else {
                    throw EzPDFError.invalidInput("That PDF is \(kb(data.count)), over the 4 MB inline limit. Ask for fewer pages (e.g. pages \"1-20\"), or use export_file.")
                }
                let resource: [String: Any] = ["type": "resource", "resource": [
                    "uri": "ezpdf://documents/\(rec.id).pdf", "mimeType": "application/pdf", "blob": data.base64EncodedString()]]
                return ToolOutput(text: "“\(rec.title)” (\(kb(data.count))) attached.", structured: nil, extra: [resource])
            },

            MCPTool(name: "manage_document", title: "Open, rename, undo or delete",
                    description: "open: show the document in the ezpdf window (optionally at a page). rename: change its title. undo_last_edit: revert the last page/annotation/compress change. delete: move it to the Trash.",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "action": S.string("What to do", enum: ["open", "rename", "undo_last_edit", "delete"]),
                        "title": S.string("rename: new title"),
                        "page": S.int("open: 1-based page"),
                    ], required: ["id", "action"]),
                    readOnly: false, destructive: true) { a in
                let id = try a.need("id")
                switch a.str("action") {
                case "open": let r = try ops.requestOpen(id, page: a.int("page")); return ToolOutput(text: "Opened “\(r.title)” in ezpdf.", structured: doc(r))
                case "rename": let r = try ops.rename(id, title: try a.need("title")); return ToolOutput(text: "Renamed to “\(r.title)”.", structured: doc(r))
                case "undo_last_edit": let r = try ops.undo(id); return ToolOutput(text: "Restored the previous version of “\(r.title)”.", structured: doc(r))
                case "delete": let r = try ops.delete(id); return ToolOutput(text: "Moved “\(r.title)” to the Trash.", structured: ["id": r.id])
                default: throw EzPDFError.invalidInput("Unknown action.")
                }
            },
        ]
    }

    static func kb(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    static func summarize(_ r: ExtractionResult, maxRows: Int, saved: URL?) -> ToolOutput {
        let enc = JSONEncoder()
        var structured = (try? JSONSerialization.jsonObject(with: enc.encode(r))) as? [String: Any] ?? [:]
        var text = ""
        switch r.kind {
        case .statement:
            let s = r.statement!
            text = "\(s.transactions.count) transactions. In \(Money.format(s.totalIn)), out \(Money.format(s.totalOut))"
            if let o = s.openingBalance { text += ", opening \(Money.format(o))" }
            if let c = s.closingBalance { text += ", closing \(Money.format(c))" }
            if let share = s.reconciledShare { text += ". \(Int(share * 100))% of rows match the running balance" }
            text += "."
            if !s.warnings.isEmpty { text += "\n⚠︎ " + s.warnings.joined(separator: "\n⚠︎ ") }
            let rows = s.transactions.prefix(maxRows).map { "\($0.date)  \(Money.format($0.amount))  \($0.description)" }
            text += "\n\n" + rows.joined(separator: "\n")
            if s.transactions.count > maxRows {
                text += "\n… \(s.transactions.count - maxRows) more (save_as csv/xlsx for all)."
                if var st = structured["statement"] as? [String: Any], let t = st["transactions"] as? [Any] {
                    st["transactions"] = Array(t.prefix(maxRows)); structured["statement"] = st
                }
            }
        case .invoice:
            let i = r.invoice!
            text = i.fieldRows.dropFirst().filter { !$0[1].isEmpty }.map { "\($0[0]): \($0[1])" }.joined(separator: "\n")
            if !i.lineItems.isEmpty { text += "\n\nLine items:\n" + i.itemRows.map { $0.filter { !$0.isEmpty }.joined(separator: " | ") }.joined(separator: "\n") }
            if !i.warnings.isEmpty { text += "\n⚠︎ " + i.warnings.joined(separator: "\n⚠︎ ") }
        default:
            let t = r.tables ?? []
            text = t.isEmpty ? "No tables found." : "\(t.count) table\(t.count == 1 ? "" : "s").\n\n" + t.prefix(5).map { tb in
                "Page \(tb.page):\n" + tb.rows.prefix(maxRows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }
        if let saved { text += "\n\nSaved to \(saved.path)"; structured["saved_path"] = saved.path }
        return ToolOutput(text: text, structured: structured)
    }
}
