import Foundation
import AppKit

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
                    readOnly: false, openWorld: true) { a, ctx in
                guard let url = URL(string: try a.need("url")), url.scheme?.hasPrefix("http") == true else { throw EzPDFError.invalidInput("Give an http(s) URL.") }
                let rec = try await ops.convert(url: url, preset: PagePreset.parse(a.str("preset")), format: OutputFormat.parse(a.str("format")),
                                                title: a.str("title"), source: .agent)
                let notes = ops.jobs.first { $0.documentID == rec.id }?.notes ?? []
                return ToolOutput(text: "Saved \(line(rec)).\(notes.isEmpty ? "" : " " + notes.joined(separator: " "))", structured: doc(rec))
            },

            MCPTool(name: "convert_file", title: "Make a PDF from a file",
                    description: "Convert files (images, Word, RTF, Markdown, text, HTML, CSV, or a PDF to import) into one PDF in the library. Send file bytes as base64 with a file name. Local agents may instead pass paths inside the user's Downloads, Desktop or Documents folders.",
                    schema: S.object([
                        "paths": S.strings("Local agents only: absolute paths inside ~/Downloads, ~/Desktop or ~/Documents; several are combined in order"),
                        "content_base64": S.string("File bytes as base64 (alternative to paths, max 20 MB)"),
                        "file_name": S.string("File name with extension, required with content_base64"),
                        "preset": S.string("Page size", enum: presetValues),
                        "title": S.string("Optional title"),
                    ]),
                    readOnly: false) { a, ctx in
                let preset = PagePreset.parse(a.str("preset"))
                let rec: DocumentRecord
                if let b64 = a.str("content_base64") {
                    guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { throw EzPDFError.invalidInput("content_base64 isn't valid base64.") }
                    rec = try await ops.convert(data: data, fileName: try a.need("file_name"), preset: preset)
                } else {
                    guard !ctx.isRemote else {
                        throw EzPDFError.invalidInput("Remote callers can't read files on this Mac. Send the file as content_base64 instead.")
                    }
                    let raw = (a["paths"] as? [String] ?? []).prefix(50)
                    guard !raw.isEmpty else { throw EzPDFError.invalidInput("Give paths or content_base64.") }
                    let paths = try raw.map { try FileAccess.checkedAgentPath($0) }
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
                    readOnly: true, idempotent: true) { a, ctx in
                let docs = ops.list(query: a.str("query"), kind: a.str("kind").flatMap(DocumentRecord.Kind.init), limit: a.int("limit", in: 1...200) ?? 25)
                let text = docs.isEmpty ? "No documents match." : docs.map { "• " + line($0) }.joined(separator: "\n")
                return ToolOutput(text: text, structured: ["documents": docs.map(doc)])
            },

            MCPTool(name: "get_document", title: "Document details",
                    description: "Details of one document: title, source, page count, and its table of contents with page numbers.",
                    schema: S.object(["id": S.string("Document id or title")], required: ["id"]),
                    readOnly: true, idempotent: true) { a, ctx in
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
                    readOnly: true, idempotent: true) { a, ctx in
                let r = try await ops.text(try a.need("id"), pages: a.str("pages"), maxChars: a.int("max_chars", in: 500...200_000) ?? 40_000)
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
                    readOnly: true, idempotent: true) { a, ctx in
                let hits = try await ops.search(try a.need("query"), in: a.str("id"), limit: a.int("limit", in: 1...200) ?? 30)
                let text = hits.isEmpty ? "No matches." : hits.map { "• \($0.title) p\($0.page): …\($0.snippet)…" }.joined(separator: "\n")
                return ToolOutput(text: text, structured: ["hits": hits.map { ["id": $0.id, "title": $0.title, "page": $0.page, "snippet": $0.snippet] }])
            },

            MCPTool(name: "extract_data", title: "Extract statement / invoice data",
                    description: "Pull structured data out of a PDF: bank or credit-card statement → transactions (checked against the running balance); invoice or receipt → vendor, number, dates, totals and line items; anything else → tables. Runs on the Mac (on-device Apple Intelligence when available). Read-only; use export_file with format csv or xlsx to save a spreadsheet.",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "kind": S.string("auto (default), statement, invoice or tables", enum: ["auto", "statement", "invoice", "tables"]),
                        "max_rows": S.int("Rows to return inline (default 200)"),
                    ], required: ["id"]),
                    readOnly: true, idempotent: true) { a, ctx in
                let id = try a.need("id")
                let result = try await ops.extract(id, kind: ExtractKind.parse(a.str("kind")), source: .agent, remember: false)
                return summarize(result, maxRows: a.int("max_rows", in: 1...2000) ?? 200, saved: nil)
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
                    readOnly: false, destructive: true) { a, ctx in
                guard let action = a.str("action").flatMap(EzPDF.PageAction.init) else { throw EzPDFError.invalidInput("Unknown action.") }
                let r = try ops.pages(try a.need("id"), action: action, pages: a.str("pages"), degrees: a.int("degrees", in: -270...270) ?? 90,
                                      to: a.int("to", in: 1...100_000), every: a.int("every", in: 1...100_000),
                                      startPages: (a["start_pages"] as? [NSNumber])?.prefix(1000).map { max(1, min(100_000, $0.intValue)) })
                let text = r.created.isEmpty ? "Done. \(line(r.document))." : "Created:\n" + r.created.map { "• " + line($0) }.joined(separator: "\n")
                return ToolOutput(text: text, structured: ["document": doc(r.document), "created": r.created.map(doc)])
            },

            MCPTool(name: "merge_documents", title: "Merge",
                    description: "Combine documents, in the order given, into a new document.",
                    schema: S.object(["ids": S.strings("Document ids or titles, in order"), "title": S.string("Title for the result")], required: ["ids"]),
                    readOnly: false) { a, ctx in
                let rec = try ops.merge(a["ids"] as? [String] ?? [], title: a.str("title"))
                return ToolOutput(text: "Merged into \(line(rec)).", structured: doc(rec))
            },

            MCPTool(name: "improve_pdf", title: "Compress, OCR, protect…",
                    description: "Whole-document changes: compress (smaller), compress_strong (much smaller, lower image quality), make_searchable (OCR scanned pages), protect (add a password), unlock (remove it), page_numbers, watermark, flatten (burn annotations and form values into the pages).",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "action": S.string("What to do", enum: EzPDF.Optimization.allCases.map(\.rawValue) + ["flatten"]),
                        "password": S.string("protect / unlock: the password"),
                        "text": S.string("watermark: the text"),
                    ], required: ["id", "action"]),
                    readOnly: false, destructive: true) { a, ctx in
                if a.str("action") == "flatten" {
                    let rec = try ops.flatten(try a.need("id"))
                    return ToolOutput(text: "Flattened “\(rec.title)”: annotations and form values are now part of the pages.", structured: doc(rec))
                }
                guard let action = a.str("action").flatMap(EzPDF.Optimization.init) else { throw EzPDFError.invalidInput("Unknown action.") }
                let r = try await ops.optimize(try a.need("id"), action, password: a.str("password"), text: a.str("text"))
                let size = action == .compress || action == .compress_strong
                    ? (r.after < r.before ? " \(kb(r.before)) → \(kb(r.after))." : " It was already as small as this setting gets.") : ""
                return ToolOutput(text: "Done: \(action.rawValue) on “\(r.record.title)”.\(size)", structured: ["document": doc(r.record), "bytes_before": r.before, "bytes_after": r.after])
            },

            MCPTool(name: "annotate", title: "Highlight or add a note",
                    description: "Highlight every occurrence of some text, add a sticky note to a page, list the annotations, or remove them (optionally only some types such as Highlight, Text, Square, Ink).",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "action": S.string("highlight, note, list or remove", enum: ["highlight", "note", "list", "remove"]),
                        "text": S.string("highlight: text to find; note: the note; remove: annotation type to remove (optional)"),
                        "page": S.int("note: 1-based page"),
                        "pages": S.string("highlight: only these pages"),
                    ], required: ["id", "action"]),
                    readOnly: false) { a, ctx in
                let id = try a.need("id")
                if a.str("action") == "list" {
                    let list = try ops.listAnnotations(id)
                    return ToolOutput(text: list.isEmpty ? "No annotations." : list.prefix(200).map { "p\($0.page) \($0.type)\($0.text.map { ": " + $0 } ?? "")" }.joined(separator: "\n"))
                }
                if a.str("action") == "remove" {
                    let r = try ops.removeAnnotations(id, pages: a.str("pages"), types: a.str("text").map { [$0] })
                    return ToolOutput(text: "Removed \(r.count) annotation\(r.count == 1 ? "" : "s").", structured: doc(r.record))
                }
                let text = try a.need("text")
                if a.str("action") == "note" {
                    let rec = try ops.addNote(id, page: a.int("page", in: 1...100_000) ?? 1, text: text)
                    return ToolOutput(text: "Added a note to page \(a.int("page", in: 1...100_000) ?? 1) of “\(rec.title)”.", structured: doc(rec))
                }
                let r = try ops.highlight(id, text: text, pages: a.str("pages"))
                return ToolOutput(text: "Highlighted \(r.count) place\(r.count == 1 ? "" : "s") in “\(r.record.title)”.", structured: doc(r.record))
            },

            MCPTool(name: "page_layout", title: "See a page's layout",
                    description: "A page's size and every line of text with its box (points, origin at the TOP-left). Use it before placing text, images, signatures or boxes so they line up with what's already there.",
                    schema: S.object(["id": S.string("Document id or title"), "page": S.int("1-based page")], required: ["id", "page"]),
                    readOnly: true, idempotent: true) { a, ctx in
                let l = try await ops.pageLayout(try a.need("id"), page: a.int("page", in: 1...100_000) ?? 1)
                let lines = l.lines.prefix(120).map { "[\(Int($0.rect[0])),\(Int($0.rect[1])) \(Int($0.rect[2]))×\(Int($0.rect[3]))] \($0.text)" }.joined(separator: "\n")
                let structured = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(l))) ?? [:]
                return ToolOutput(text: "Page \(l.page): \(Int(l.width)) × \(Int(l.height)) points (x from left, y from top).\n\(lines)", structured: structured)
            },

            MCPTool(name: "edit_text", title: "Change text",
                    description: "Replace words or lines in the document: each match is painted over in its background color and the new text is written in the same font, size and color on the same baseline. Use replace \"\" to erase. This changes how the page looks; for removing sensitive text use redact. Changes the document (undo_last_edit reverts).",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "find": S.string("Only the exact words that are wrong, as printed, e.g. the old date \"11/13/2026\" (not its label)"),
                        "replace": S.string("What those words should say instead, e.g. \"12/01/2026\""),
                        "pages": S.string("Only these pages, e.g. 1-3"),
                        "match_case": S.bool("Match upper/lower case (default false)"),
                        "whole_word": S.bool("Only whole words (default false)"),
                    ], required: ["id", "find", "replace"]),
                    readOnly: false, destructive: true) { a, ctx in
                guard let find = a["find"] as? String, !find.isEmpty, let rep = a["replace"] as? String else { throw EzPDFError.invalidInput("Give find and replace.") }
                // The new words go in the document's own font: make sure it's here first.
                await ops.prepareFonts(try a.need("id"))
                let r = try ops.replaceText(try a.need("id"), find: find, with: rep, pages: a.str("pages"),
                                            matchCase: a.bool("match_case") ?? false, wholeWord: a.bool("whole_word") ?? false)
                let pages = Set(r.changes.map(\.page)).sorted().map(String.init).joined(separator: ", ")
                // What the edit checks adjusted or noticed, once each.
                var notes: [String] = []
                for n in r.changes.flatMap(\.notes) where !notes.contains(n) { notes.append(n) }
                let applied = Set(r.changes.map(\.new)).count == 1 && r.changes[0].new != rep ? " as “\(r.changes[0].new)”" : ""
                return ToolOutput(text: "Changed \(r.changes.count) place\(r.changes.count == 1 ? "" : "s") on page\(r.changes.count == 1 ? "" : "s") \(pages)\(applied)." + (notes.isEmpty ? "" : " Notes: " + notes.prefix(6).joined(separator: " ")), structured: doc(r.record))
            },

            MCPTool(name: "add_content", title: "Add text, image, signature or box",
                    description: "Put new content on a page at a box given in points from the TOP-left (see page_layout for positions). kind: text (real, selectable text), image, signature (typed name in a handwriting font, or an image), shape (rectangle, ellipse, line, arrow annotation), whiteout (cover an area in its background color).",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "kind": S.string("What to add", enum: EzPDF.ContentKind.allCases.map(\.rawValue)),
                        "page": S.int("1-based page"),
                        "x": S.int("Left edge, points from the left"),
                        "y": S.int("Top edge, points from the top"),
                        "width": S.int("Width in points"),
                        "height": S.int("Height in points"),
                        "text": S.string("text: the words to add; signature: the name to sign (defaults to the user's saved signature name)"),
                        "font": S.string("Font name, e.g. Helvetica, Times New Roman (default system font)"),
                        "font_size": S.int("Points (default 12)"),
                        "color": S.string("#RRGGBB or a name like red, blue, navy"),
                        "align": S.string("left, center or right", enum: ["left", "center", "right"]),
                        "shape": S.string("For kind shape", enum: EditOps.Shape.allCases.map(\.rawValue)),
                        "image_base64": S.string("image/signature: the image as base64"),
                        "image_path": S.string("Local agents only: an image in Downloads, Desktop or Documents"),
                    ], required: ["id", "kind", "page", "x", "y", "width", "height"]),
                    readOnly: false, destructive: true) { a, ctx in
                guard let kind = a.str("kind").flatMap(EzPDF.ContentKind.init) else { throw EzPDFError.invalidInput("Unknown kind.") }
                var image: Data?
                if let b64 = a.str("image_base64") {
                    guard let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), d.count < 20_000_000 else { throw EzPDFError.invalidInput("image_base64 isn't a valid image.") }
                    image = d
                } else if let path = a.str("image_path") {
                    guard !ctx.isRemote else { throw EzPDFError.invalidInput("Remote callers must send image_base64.") }
                    image = try Data(contentsOf: try FileAccess.checkedAgentPath(path))
                }
                let rect = CGRect(x: a.int("x", in: -10_000...100_000) ?? 0, y: a.int("y", in: -10_000...100_000) ?? 0,
                                  width: a.int("width", in: 1...100_000) ?? 100, height: a.int("height", in: 1...100_000) ?? 20)
                let align: NSTextAlignment = a.str("align") == "center" ? .center : a.str("align") == "right" ? .right : .left
                let rec = try ops.addContent(try a.need("id"), .init(kind: kind, page: a.int("page", in: 1...100_000) ?? 1, rect: rect,
                    text: a["text"] as? String, fontName: a.str("font"), fontSize: a.int("font_size", in: 4...400).map { CGFloat($0) },
                    color: ColorName.parse(a.str("color")), alignment: align, imageData: image, shape: a.str("shape").flatMap(EditOps.Shape.init)))
                return ToolOutput(text: "Added \(kind.rawValue) on page \(a.int("page", in: 1...100_000) ?? 1) of “\(rec.title)”.", structured: doc(rec))
            },

            MCPTool(name: "sign", title: "Sign",
                    description: "Sign the document with the person's name in a handwriting style (or a signature image). Without a box it places the signature on the signature line, or at the bottom right of the last page.",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "name": S.string("The name to sign"),
                        "page": S.int("1-based page (default: the last page)"),
                        "x": S.int("Optional box left, points from the left"), "y": S.int("Optional box top, points from the top"),
                        "width": S.int("Optional box width"), "height": S.int("Optional box height"),
                        "image_base64": S.string("Optional signature image as base64"),
                    ], required: ["id", "name"]),
                    readOnly: false, destructive: true) { a, ctx in
                var rect: CGRect?
                if let x = a.int("x", in: 0...100_000), let y = a.int("y", in: 0...100_000) {
                    rect = CGRect(x: x, y: y, width: a.int("width", in: 20...2000) ?? 180, height: a.int("height", in: 10...600) ?? 40)
                }
                let image = a.str("image_base64").flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
                let r = try await ops.sign(try a.need("id"), name: a.str("name"), imageData: image, page: a.int("page", in: 1...100_000), rect: rect)
                return ToolOutput(text: "Signed on page \(r.page) at x \(Int(r.rect.minX)), y \(Int(r.rect.minY)).", structured: doc(r.record))
            },

            MCPTool(name: "add_header_footer", title: "Header, footer, page numbers, logo",
                    description: "Add a header and/or footer to pages (left, center, right), page numbers, Bates numbers, dates, the title, or a logo. Text tokens: @page, @total, @date, @date{MMM d, yyyy}, @time, @year, @title, @author, @filename, @bates, @@ for a literal @. Example: footer_center \"Page @page of @total\".",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "header_left": S.string("Header text, left"), "header_center": S.string("Header text, center"), "header_right": S.string("Header text, right"),
                        "footer_left": S.string("Footer text, left"), "footer_center": S.string("Footer text, center"), "footer_right": S.string("Footer text, right"),
                        "font_size": S.int("Points (default 9)"), "color": S.string("#RRGGBB or a color name (default dark gray)"),
                        "margin": S.int("Distance from the page edge in points (default 30)"),
                        "skip_first_page": S.bool("Leave the first page (cover) alone"),
                        "mirror_even_pages": S.bool("Swap left and right on even pages"),
                        "pages": S.string("Only these pages, e.g. 2-"),
                        "bates_prefix": S.string("Prefix for @bates, e.g. ACME-"), "bates_start": S.int("First Bates number (default 1)"),
                        "bates_digits": S.int("Digits, zero-padded (default 6)"),
                        "logo_base64": S.string("Logo image as base64"), "logo_path": S.string("Local agents only: logo in Downloads, Desktop or Documents"),
                        "logo_position": S.string("Where the logo goes", enum: Stamps.LogoPosition.allCases.map(\.rawValue)),
                        "logo_height": S.int("Logo height in points (default 28)"),
                    ], required: ["id"]),
                    readOnly: false, destructive: true) { a, ctx in
                let id = try a.need("id")
                var c = Stamps.Config()
                c.headerLeft = a["header_left"] as? String ?? ""; c.headerCenter = a["header_center"] as? String ?? ""; c.headerRight = a["header_right"] as? String ?? ""
                c.footerLeft = a["footer_left"] as? String ?? ""; c.footerCenter = a["footer_center"] as? String ?? ""; c.footerRight = a["footer_right"] as? String ?? ""
                if let fs = a.int("font_size", in: 5...48) { c.fontSize = CGFloat(fs) }
                if let col = ColorName.parse(a.str("color")) { c.color = col }
                if let m = a.int("margin", in: 18...200) { c.margin = CGFloat(m) }
                c.skipFirstPage = a.bool("skip_first_page") ?? false
                c.mirrorEvenPages = a.bool("mirror_even_pages") ?? false
                c.batesPrefix = a.str("bates_prefix") ?? ""
                c.batesStart = a.int("bates_start", in: 0...99_999_999) ?? 1
                c.batesDigits = a.int("bates_digits", in: 1...12) ?? 6
                if let b64 = a.str("logo_base64") { c.logo = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) }
                else if let path = a.str("logo_path") {
                    guard !ctx.isRemote else { throw EzPDFError.invalidInput("Remote callers must send logo_base64.") }
                    c.logo = try Data(contentsOf: try FileAccess.checkedAgentPath(path))
                }
                if let p = a.str("logo_position").flatMap(Stamps.LogoPosition.init) { c.logoPosition = p }
                if let h = a.int("logo_height", in: 8...200) { c.logoHeight = CGFloat(h) }
                if let spec = a.str("pages") {
                    let (_, doc) = try ops.document(id)
                    c.pages = Set(try PageOps.pages(spec, count: doc.pageCount))
                }
                let r = try ops.stamp(id, c)
                return ToolOutput(text: "Added to \(r.pages) page\(r.pages == 1 ? "" : "s") of “\(r.record.title)”.", structured: doc(r.record))
            },

            MCPTool(name: "create_from_template", title: "New document from a template",
                    description: "Make a new fillable document from a template: a ready-made one (invoice, receipt, quote, purchase_order, packing_slip, letter, cover_letter, resume, nda, bill_of_sale, rental, timesheet, expense_report, minutes, vendor_form, job_application, consent, permission_slip, certificate, event_registration) or one the user saved (call with template \"list\" to see saved ones and their fields). Call with template only to create it blank, then use fill_form to fill it (fill_form with no values lists the fields).",
                    schema: S.object([
                        "template": S.string("Template id, a saved template's name or id, or \"list\""),
                        "title": S.string("Title for the new document"),
                        "values": ["description": "Optional field values (object), see fill_form", "type": ["object", "string"]],
                    ], required: ["template"]),
                    readOnly: false) { a, ctx in
                let name = try a.need("template")
                if name.lowercased() == "list" {
                    let saved = ops.userTemplates()
                    let lines = saved.prefix(50).map { "- \($0.name) (id \($0.id)), \($0.pageCount) page(s), fields: \($0.fields.prefix(30).joined(separator: ", "))" }
                    return ToolOutput(text: saved.isEmpty ? "No saved templates yet. Ready-made: \(DocTemplate.all.map(\.id).joined(separator: ", "))."
                                                          : "Saved templates:\n" + lines.joined(separator: "\n"))
                }
                var values: [String: String] = [:]
                if let obj = a["values"] as? [String: Any] { for (k, v) in obj.prefix(500) { values[k] = (v as? String) ?? "\(v)" } }
                if let t = DocTemplate.find(name) {
                    let rec = try await ops.create(template: t, values: values, title: a.str("title"), source: .agent)
                    return ToolOutput(text: "Created \(line(rec)) from the \(t.name) template. Fields: \(t.fieldNames.prefix(40).joined(separator: ", "))\(t.fieldNames.count > 40 ? ", …" : "").", structured: doc(rec))
                }
                guard let saved = ops.userTemplate(name) else {
                    throw EzPDFError.invalidInput("No template “\(name)”. Use a ready-made id, or template \"list\" for saved ones.")
                }
                let rec = try ops.create(userTemplate: saved.id, title: a.str("title"), values: values, source: .agent)
                return ToolOutput(text: "Created \(line(rec)) from the saved template “\(saved.name)”. Fields: \(saved.fields.prefix(40).joined(separator: ", "))\(saved.fields.count > 40 ? ", …" : "").", structured: doc(rec))
            },

            MCPTool(name: "memory", title: "Remember",
                    description: "What to remember about the person across conversations: preferences and facts they want kept (\"sign as Hari L.\", \"dates as DD/MM/YYYY\", \"my company is Northwind Design\"). action get lists the notes; remember saves text (only things they said to remember, or clear lasting preferences, never secrets or account numbers); forget removes notes by id or by matching text.",
                    schema: S.object([
                        "action": S.string("get, remember or forget", enum: ["get", "remember", "forget"]),
                        "text": S.string("remember: the note (under 300 characters); forget: text to match"),
                        "note_id": S.string("forget: the note's id"),
                    ], required: ["action"]),
                    readOnly: false) { a, ctx in
                switch a.str("action") {
                case "get":
                    let notes = ops.memory()
                    guard !notes.isEmpty else { return ToolOutput(text: "Nothing remembered yet.") }
                    return ToolOutput(text: notes.reversed().map { "- \($0.text) (id \($0.id), from \($0.source))" }.joined(separator: "\n"))
                case "remember":
                    let n = try ops.remember(try a.need("text"), source: ctx.client ?? "an agent")
                    return ToolOutput(text: "Remembered: \(n.text)")
                case "forget":
                    let gone = try ops.forget(id: a.str("note_id"), matching: a.str("text"))
                    return ToolOutput(text: "Forgot: " + gone.map(\.text).joined(separator: "; "))
                default:
                    throw EzPDFError.invalidInput("action is get, remember or forget.")
                }
            },

            MCPTool(name: "document_history", title: "Document history",
                    description: "What happened to a document: each change with who made it (the person, the ezpdf assistant, or which agent), what it was, and whether it worked. Newest first.",
                    schema: S.object(["id": S.string("Document id or title"), "limit": S.int("How many (default 30)")], required: ["id"]),
                    readOnly: true) { a, ctx in
                let events = try ops.history(try a.need("id"), limit: a.int("limit", in: 1...500) ?? 30)
                guard !events.isEmpty else { return ToolOutput(text: "No changes recorded yet.") }
                let f = ISO8601DateFormatter()
                return ToolOutput(text: events.map { e in
                    "- \(f.string(from: e.at)) \(e.by): \(e.action)\(e.ok ? "" : " (failed: \(e.result))")\(e.detail.isEmpty ? "" : " — " + e.detail.replacingOccurrences(of: "\n", with: "; "))"
                }.joined(separator: "\n"))
            },

            MCPTool(name: "fonts", title: "Document fonts",
                    description: "List the fonts a document uses and whether edits can use them: on this Mac, taken from the document, or fetched (open-licensed families from the Google Fonts collection; Calibri and Cambria get their same-width open twins). Fetching happens automatically before edits; call with fetch true to do it now or again.",
                    schema: S.object(["id": S.string("Document id or title"), "fetch": S.bool("Fetch missing open fonts again now")], required: ["id"]),
                    readOnly: true, openWorld: true) { a, ctx in
                let status = await ops.prepareFonts(try a.need("id"), force: a.bool("fetch") ?? false)
                guard !status.isEmpty else { return ToolOutput(text: "No fonts found in that document (it may be scanned images).") }
                let text = status.map { "- \($0.name): \($0.source.rawValue). \($0.detail)" }.joined(separator: "\n")
                return ToolOutput(text: "Fonts:\n" + text)
            },

            MCPTool(name: "make_fillable", title: "Make a form fillable",
                    description: "Turn a printed or scanned form into a fillable one: finds the writing lines, boxes, table cells, checkboxes and signature/date lines and adds a named form field for each (named after its label, e.g. full_name). Existing fields are kept. Optionally saves the result as a reusable template. Then fill it with fill_form. Changes the document (undo_last_edit reverts).",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "save_as_template": S.string("Also keep it in My Templates under this name"),
                    ], required: ["id"]),
                    readOnly: false) { a, ctx in
                let r = try await ops.makeFillable(try a.need("id"))
                var text = "Added \(r.fields.count) fields to \(line(r.record)): " + r.fields.prefix(60).map { "\($0.name) (\($0.kind.rawValue), page \($0.page + 1))" }.joined(separator: ", ")
                if !r.skippedRotated.isEmpty { text += ". Rotated pages with annotations were left as they were: \(r.skippedRotated.map(String.init).joined(separator: ", "))." }
                if let name = a.str("save_as_template"), !name.isEmpty {
                    let t = try ops.saveTemplate(r.record.id, name: name)
                    text += " Saved as the template “\(t.name)”."
                }
                return ToolOutput(text: text, structured: doc(r.record))
            },

            MCPTool(name: "generate_logo", title: "Generate a logo or image",
                    description: "Make a logo, stamp, seal or small picture from a description and put it on a page as a movable object (background removed). Uses the model chosen in ezpdf (Apple Image Playground is free; fal.ai or OpenAI if the user added a key). Only for local use.",
                    schema: S.object([
                        "id": S.string("Document id or title to place it on"),
                        "prompt": S.string("What it should look like, e.g. \"Bean There coffee, a bean with a map pin\""),
                        "style": S.string("Look", enum: ImageGen.Style.allCases.map(\.rawValue)),
                        "page": S.int("1-based page (default 1)"),
                        "x": S.int("Left, points from the left (default 48)"), "y": S.int("Top, points from the top (default 40)"),
                        "width": S.int("Width in points (default 110)"),
                    ], required: ["id", "prompt"]),
                    readOnly: false, destructive: true, openWorld: true) { a, ctx in
                guard !ctx.isRemote else { throw EzPDFError.invalidInput("Image generation uses the user's own keys, so it's only available from this Mac.") }
                // Paid calls on the user's key: at most a few a minute, whoever asks.
                guard LogoRate.allow() else { throw EzPDFError.invalidInput("Several logos were just made; wait a minute before making more.") }
                let model = ImageGen.model(id: UserDefaults.standard.string(forKey: "ezpdf.logoModel"))
                if model.provider == .apple, !NSApplication.shared.isActive {
                    throw EzPDFError.invalidInput("Image Playground only works while ezpdf is in front. Bring ezpdf forward, or pick a fal.ai, OpenAI or OpenRouter model in ezpdf Settings › Models.")
                }
                let style = a.str("style").flatMap(ImageGen.Style.init(rawValue:)) ?? .minimal
                guard let raw = try await ImageGen.generate(prompt: ImageGen.prompt(try a.need("prompt"), style: style), model: model, count: 1).first else {
                    throw EzPDFError.failed("No image came back.")
                }
                let png = (try? await ImageGen.removeBackground(raw, lettering: style.isLettering)) ?? raw
                let w = a.int("width", in: 20...600) ?? 110
                let rec = try ops.addContent(try a.need("id"), .init(kind: .image, page: a.int("page", in: 1...100_000) ?? 1,
                    rect: CGRect(x: a.int("x", in: 0...5000) ?? 48, y: a.int("y", in: 0...5000) ?? 40, width: w, height: w), imageData: png))
                return ToolOutput(text: "Made the image with \(model.name) and placed it on page \(a.int("page", in: 1...100_000) ?? 1). The user can drag it or resize it.", structured: doc(rec))
            },

            MCPTool(name: "fill_form", title: "Fill in a form",
                    description: "List a PDF form's fields (call with no values), or fill them. values: field name → value; checkboxes take true/false, radio buttons the option name. Also accepts lines like \"Name = Jane\".",
                    schema: S.object(["id": S.string("Document id or title"),
                                      "values": ["description": "Field values: an object, or \"Field = value\" lines", "type": ["object", "string"]]],
                                     required: ["id"]),
                    readOnly: false, destructive: true) { a, ctx in
                let id = try a.need("id")
                var values: [String: String] = [:]
                if let obj = a["values"] as? [String: Any] {
                    for (k, v) in obj.prefix(500) { values[k] = (v as? String) ?? (v as? NSNumber)?.stringValue ?? String(describing: v) }
                } else if let text = a["values"] as? String {
                    for line in text.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
                        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        if parts.count == 2, !parts[0].isEmpty { values[parts[0]] = parts[1] }
                    }
                }
                if values.isEmpty {
                    let fields = try ops.formFields(id)
                    let text = fields.isEmpty ? "This PDF has no fillable form fields. Use add_content to type onto it instead." :
                        fields.prefix(200).map { "• \($0.name) (\($0.type), page \($0.page))\($0.value.isEmpty ? "" : " = \($0.value)")\($0.options.map { " options: " + $0.joined(separator: ", ") } ?? "")" }.joined(separator: "\n")
                    return ToolOutput(text: text, structured: ["fields": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(fields))) ?? []])
                }
                let r = try ops.fillForm(id, values: values)
                let missing = Set(values.keys).subtracting(r.filled).sorted()
                return ToolOutput(text: "Filled \(r.filled.count) field\(r.filled.count == 1 ? "" : "s").\(missing.isEmpty ? "" : " Not found: " + missing.joined(separator: ", ") + ".")", structured: doc(r.record))
            },

            MCPTool(name: "redact", title: "Redact",
                    description: "Permanently remove text or areas: every occurrence of `text`, and/or one box (page + x, y, width, height from the top-left). The pages are rebuilt so nothing under the black boxes can be recovered; their other text stays searchable.",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "text": S.string("Text to remove everywhere it appears (e.g. an account number)"),
                        "pages": S.string("Limit text redaction to these pages"),
                        "page": S.int("Box: 1-based page"), "x": S.int("Box left"), "y": S.int("Box top"),
                        "width": S.int("Box width"), "height": S.int("Box height"),
                    ], required: ["id"]),
                    readOnly: false, destructive: true) { a, ctx in
                var boxes: [(page: Int, rect: CGRect)] = []
                if let p = a.int("page", in: 1...100_000), let w = a.int("width", in: 1...100_000), let h = a.int("height", in: 1...100_000) {
                    boxes.append((p, CGRect(x: a.int("x", in: 0...100_000) ?? 0, y: a.int("y", in: 0...100_000) ?? 0, width: w, height: h)))
                }
                let r = try await ops.redact(try a.need("id"), text: a.str("text"), boxes: boxes, pages: a.str("pages"))
                return ToolOutput(text: "Redacted \(r.count) area\(r.count == 1 ? "" : "s") on page\(r.pages.count == 1 ? "" : "s") \(r.pages.map(String.init).joined(separator: ", ")).", structured: doc(r.record))
            },

            MCPTool(name: "send_to_kindle", title: "Send to Kindle",
                    description: "Email a document to the user's Kindle (address set in ezpdf Settings). Uses the EPUB when there is one, since Kindle reflows it; otherwise the PDF.",
                    schema: S.object(["id": S.string("Document id or title"), "format": S.string("Force pdf or epub", enum: ["pdf", "epub"])], required: ["id"]),
                    readOnly: false, openWorld: true) { a, ctx in
                let r = try await ops.sendToKindle(try a.need("id"), format: a.str("format").flatMap(EzPDF.ExportFormat.init))
                return ToolOutput(text: "Sent “\(r.record.title)” as \(r.format.rawValue.uppercased()) to \(r.address). It usually appears on the Kindle within a few minutes.", structured: doc(r.record))
            },

            MCPTool(name: "export_file", title: "Save a copy",
                    description: "Save the PDF or EPUB, or the extracted data as a spreadsheet (csv, xlsx or json), to the user's ezpdf export folder (Downloads unless changed) and return its path.",
                    schema: S.object(["id": S.string("Document id or title"),
                                      "format": S.string("pdf (default), epub, or csv/xlsx/json for extracted data", enum: ["pdf", "epub", "csv", "xlsx", "json"]),
                                      "kind": S.string("For csv/xlsx/json: auto, statement, invoice or tables", enum: ["auto", "statement", "invoice", "tables"]),
                                      "subfolder": S.string("Optional folder name inside the export folder")], required: ["id"]),
                    readOnly: false) { a, ctx in
                let id = try a.need("id")
                let folder = try a.str("subfolder").map { try FileAccess.exportSubfolder($0, in: ops.exportFolder) }
                let format = a.str("format") ?? "pdf"
                let url: URL
                if let data = EzPDF.DataFormat(rawValue: format) {
                    let result = try await ops.extract(id, kind: ExtractKind.parse(a.str("kind")), source: .agent)
                    url = try ops.saveExtraction(result, for: id, format: data, folder: folder)
                } else {
                    url = try ops.export(id, format: EzPDF.ExportFormat(rawValue: format) ?? .pdf, folder: folder)
                }
                return ToolOutput(text: "Saved to \(url.path)", structured: ["path": url.path])
            },

            MCPTool(name: "get_pdf", title: "Get the PDF file",
                    description: "Return the PDF itself (embedded, base64) so you can read or attach it. Limited to 4 MB; use pages to send part of a large document, or export_file to save it on the Mac.",
                    schema: S.object(["id": S.string("Document id or title"), "pages": S.string("Only these pages, e.g. 1-10")], required: ["id"]),
                    readOnly: true, idempotent: true) { a, ctx in
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
                    description: "open: show the document in the ezpdf window (optionally at a page). rename: change its title. properties: set the PDF's title, author, subject, keywords. undo_last_edit: revert the last change. delete: move it to the Trash.",
                    schema: S.object([
                        "id": S.string("Document id or title"),
                        "action": S.string("What to do", enum: ["open", "rename", "properties", "undo_last_edit", "redo_last_edit", "delete"]),
                        "title": S.string("rename/properties: new title"),
                        "author": S.string("properties: author"), "subject": S.string("properties: subject"),
                        "keywords": S.string("properties: comma-separated keywords"),
                        "page": S.int("open: 1-based page"),
                    ], required: ["id", "action"]),
                    readOnly: false, destructive: true) { a, ctx in
                let id = try a.need("id")
                switch a.str("action") {
                case "open": let r = try ops.requestOpen(id, page: a.int("page", in: 1...100_000)); return ToolOutput(text: "Opened “\(r.title)” in ezpdf.", structured: doc(r))
                case "rename": let r = try ops.rename(id, title: try a.need("title")); return ToolOutput(text: "Renamed to “\(r.title)”.", structured: doc(r))
                case "properties":
                    let r = try ops.setProperties(id, title: a.str("title"), author: a.str("author"), subject: a.str("subject"),
                                                  keywords: a.str("keywords").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
                    return ToolOutput(text: "Updated the properties of “\(r.title)”.", structured: doc(r))
                case "undo_last_edit": let r = try ops.undo(id); return ToolOutput(text: "Restored the previous version of “\(r.title)”. Undo again to go further back; redo_last_edit puts the change back.", structured: doc(r))
                case "redo_last_edit": let r = try ops.redo(id); return ToolOutput(text: "Put back the change that was undone in “\(r.title)”.", structured: doc(r))
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

/// generate_logo spends the user's credits: 4 per minute.
@MainActor enum LogoRate {
    private static var recent: [Date] = []
    static func allow() -> Bool {
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < 4 else { return false }
        recent.append(now)
        return true
    }
}
