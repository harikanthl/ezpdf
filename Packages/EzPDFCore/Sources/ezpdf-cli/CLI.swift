import Foundation
import EzPDFCore
import PDFKit
import OperatorLLM

@MainActor
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        guard let cmd = args.first else { usage(); return 2 }
        do {
            switch cmd {
            case "web":
                guard args.count >= 3, let url = URL(string: args[1]) else { usage(); return 2 }
                let preset = PagePreset.parse(args.count > 3 ? args[3] : nil) ?? .kindle
                let out = URL(fileURLWithPath: args[2])
                let t0 = Date()
                let r = try await WebConverter.convert(url: url, preset: preset, format: .both) { fputs("· \($0)\n", stderr) }
                try r.pdf.write(to: out)
                if let e = r.epub { try e.write(to: out.deletingPathExtension().appendingPathExtension("epub")) }
                print("title: \(r.title)\nreader: \(r.usedReader)\nfinal: \(r.finalURL)\npdf bytes: \(r.pdf.count)\nepub bytes: \(r.epub?.count ?? 0)\nnotes: \(r.notes)\nsecs: \(Int(Date().timeIntervalSince(t0)))")
            case "file":
                guard args.count >= 3 else { usage(); return 2 }
                let ins = args[1..<(args.count - 1)].map { URL(fileURLWithPath: $0) }
                let out = try await FileConverter.convert(Array(ins), preset: .letter)
                try out.pdf.write(to: URL(fileURLWithPath: args.last!))
                print("title: \(out.title) bytes: \(out.pdf.count)")
            case "extract":
                guard args.count >= 2, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { usage(); return 2 }
                let r = await DataExtractor.extract(doc, kind: ExtractKind.parse(args.count > 2 ? args[2] : nil), useAI: args.count > 3 ? args[3] != "noai" : true)
                let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(data: try e.encode(r), encoding: .utf8)!)
            case "summarize":
                let rec = try await EzPDF.shared.convert(files: [URL(fileURLWithPath: args[1])], source: .cli)
                defer { _ = try? EzPDF.shared.delete(rec.id) }
                let t0 = Date()
                print(try await EzPDF.shared.summarize(rec.id))
                print("secs:", Int(Date().timeIntervalSince(t0)))
            case "html":
                // Renders a local HTML file through the web pipeline (tests the private-network block).
                let html = try String(contentsOf: URL(fileURLWithPath: args[1]), encoding: .utf8)
                let r = try await WebConverter.convert(html: html, url: URL(string: "https://example.com/")!, preset: .letter)
                try r.pdf.write(to: URL(fileURLWithPath: args[2]))
                print("pdf bytes: \(r.pdf.count) notes: \(r.notes)")
            case "rules":
                do { try await WebConverter.checkRules(); print("rules compiled") } catch { print("rules error:", error) }
            case "edit-test":
                // Exercises the editing engine on a PDF and writes the result.
                guard let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { return 2 }
                let r = try EditOps.replaceText(doc, find: args[3], with: args[4])
                print("replaced:", r.map { "p\($0.page) \($0.old)→\($0.new)" })
                try EditOps.addText(doc, page: 0, text: "Reviewed by ezpdf", rect: CGRect(x: 360, y: 40, width: 200, height: 20), fontSize: 11, color: .systemRed)
                try EditOps.addShape(doc, page: 0, shape: .rectangle, rect: CGRect(x: 50, y: 150, width: 500, height: 30))
                try EditOps.addTypedSignature(doc, page: 0, name: "Harikanth L", rect: CGRect(x: 380, y: 520, width: 180, height: 40))
                let rr = EditOps.rects(of: "4821", in: doc, pages: nil)
                for (p, rects) in rr { try EditOps.redact(doc, page: p, rects: rects) }
                guard let out = doc.dataRepresentation() else { return 1 }
                try out.write(to: URL(fileURLWithPath: args[2]))
                print("text now:", (PDFDocument(data: out)?.page(at: 0)?.string ?? "").prefix(300))
            case "assist":
                // ezpdf-cli assist <file.pdf> "<instruction>"  — on-device assistant, changes applied.
                let rec = try await EzPDF.shared.convert(files: [URL(fileURLWithPath: args[1])], source: .cli)
                let toolbox = AssistantToolbox()
                let wanted = AssistantToolbox.onDeviceTools
                let specs = wanted.compactMap { toolbox.spec(named: $0) }.filter(\.flat).map { LLMToolSpec(name: $0.name, description: $0.description, parametersJSON: $0.schemaJSON) }
                print("tools:", specs.map(\.name))
                let readOnlyNames = Set(toolbox.specs.filter(\.readOnly).map(\.name))
                let tools = OnDeviceToolBridge.tools(specs) { call in
                    let r = await toolbox.call(call.name, argumentsJSON: call.argumentsJSON, currentDocument: rec.id)
                    print("→ \(call.name) \(call.argumentsJSON)\n  \(r.ok ? "ok" : "ERR"): \(r.text.prefix(200))")
                    let t = r.text.count > 1500 ? String(r.text.prefix(1500)) + " [clipped]" : r.text
                    let readOnly = readOnlyNames.contains(call.name)
                    return r.ok ? (readOnly ? t : t + " Done. Now reply to the user in one sentence; don't call more tools unless they asked for more.") : "Error: " + t
                }
                // Optional 5th arg: words under a pen mark, sent the way the app's Mark & Talk does.
                if args.count > 4, let edit = await AssistantToolbox.markEdit(marked: args[4], request: args[2], page: 1) {
                    let json = String(decoding: try JSONSerialization.data(withJSONObject: ["find": edit.find, "replace": edit.replace, "pages": edit.pages, "match_case": true]), as: UTF8.self)
                    let r = await toolbox.call("edit_text", argumentsJSON: json, currentDocument: rec.id)
                    print("fast path → edit_text \(json)\n  \(r.ok ? "ok" : "ERR"): \(r.text)")
                    try Data(contentsOf: EzPDF.shared.library.pdfURL(for: rec.id)).write(to: URL(fileURLWithPath: args[3]))
                    _ = try? EzPDF.shared.delete(rec.id)
                    return 0
                }
                let markNote = args.count > 4 ? "\n[The user pointed with the pen at these words on page 1: \"\(args[4])\". \"this\" means those words.]" : ""
                let prompt = "User: \(args[2])\(markNote)\n[The open document is “\(rec.title)” (id \(rec.id)), \(rec.pageCount) pages; the user is looking at page 1.]"
                var reply = ""
                for try await d in OnDeviceLLM(instructions: AssistantToolbox.compactInstructions).streamText(prompt: prompt, tools: tools) { reply += d }
                print("assistant:", reply)
                let out = URL(fileURLWithPath: args.count > 3 ? args[3] : "/tmp/assist.pdf")
                try Data(contentsOf: EzPDF.shared.library.pdfURL(for: rec.id)).write(to: out)
                _ = try? EzPDF.shared.delete(rec.id)
            case "objects-test":
                let ops = EzPDF.shared
                let rec = try await ops.convert(files: [URL(fileURLWithPath: args[1])], source: .cli)
                defer { _ = try? ops.delete(rec.id) }
                try ops.addContent(rec.id, .init(kind: .text, page: 1, rect: CGRect(x: 380, y: 30, width: 200, height: 20), text: "APPROVED", fontSize: 16, color: .systemGreen))
                try ops.addContent(rec.id, .init(kind: .signature, page: 1, rect: CGRect(x: 360, y: 560, width: 200, height: 40), text: "Hari L"))
                let logo = try Data(contentsOf: URL(fileURLWithPath: args[2]))
                try ops.addContent(rec.id, .init(kind: .image, page: 1, rect: CGRect(x: 40, y: 20, width: 60, height: 60), imageData: logo))
                var objs = try ops.objects(rec.id)
                print("objects:", objs.map { "\($0.kind.rawValue) \($0.rect) \($0.text ?? "")" })
                let text = objs.first { $0.kind == .text }!
                try ops.updateObject(rec.id, object: text.id, .init(rect: CGRect(x: 400, y: 120, width: 180, height: 24), text: "APPROVED ✓", fontSize: 20, color: .systemBlue))
                let sig = objs.first { $0.kind == .signature }!
                try ops.deleteObject(rec.id, object: sig.id)
                objs = try ops.objects(rec.id)
                print("after:", objs.map { "\($0.kind.rawValue) \($0.rect) \($0.text ?? "") \($0.fontSize ?? 0)" })
                let out = try ops.deliverableData(rec.id)
                try out.write(to: URL(fileURLWithPath: args[3]))
                let d = PDFDocument(data: out)!
                print("deliverable annotations left:", d.page(at: 0)!.annotations.count, "| text has APPROVED:", (d.page(at: 0)!.string ?? "").contains("APPROVED"))
            case "stamp-test":
                let rec = try await EzPDF.shared.convert(files: [URL(fileURLWithPath: args[1])], source: .cli)
                defer { _ = try? EzPDF.shared.delete(rec.id) }
                var c = Stamps.Config()
                c.headerRight = "Confidential · @date{MMM d, yyyy}"; c.footerCenter = "Page @page of @total"; c.footerRight = "@bates"
                c.batesPrefix = "NW-"; c.logo = try Data(contentsOf: URL(fileURLWithPath: args[2]))
                _ = try EzPDF.shared.stamp(rec.id, c)
                try Data(contentsOf: EzPDF.shared.library.pdfURL(for: rec.id)).write(to: URL(fileURLWithPath: args[3]))
                print("text:", (PDFDocument(url: URL(fileURLWithPath: args[3]))?.page(at: 0)?.string ?? "").prefix(80))
            case "fonts":
                // ezpdf-cli fonts <file.pdf>: the fonts it uses and how ezpdf makes each available.
                guard let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { return 2 }
                for s in await Fonts.prepare(doc) { print("\(s.name): \(s.source.rawValue) — \(s.detail)") }
            case "detect-form":
                // ezpdf-cli detect-form <form.pdf> [out.pdf]: the blanks found. If the PDF is already fillable,
                // its fields are taken off first and compared with what's found (how many real fields were found).
                guard let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { return 2 }
                var truth: [(page: Int, rect: CGRect, checkbox: Bool)] = []
                for p in 0..<doc.pageCount {
                    guard let page = doc.page(at: p) else { continue }
                    let space = EditOps.PageSpace(page)
                    for a in page.annotations where a.type == "Widget" {
                        if a.widgetFieldType == .text || a.widgetFieldType == .button && a.widgetControlType == .checkBoxControl {
                            truth.append((p, space.topLeft(a.bounds), a.widgetFieldType == .button))
                        }
                        page.removeAnnotation(a)
                    }
                }
                let t0 = Date()
                let fields = await FormDetector.detect(doc)
                print(String(format: "%d fields in %.2fs", fields.count, Date().timeIntervalSince(t0)))
                for f in fields { print(String(format: "  p%d %-10@ %-28@ %@", f.page + 1, f.kind.rawValue as NSString, f.name as NSString, "\(f.rect.integral)" as NSString)) }
                if !truth.isEmpty {
                    func hit(_ t: (page: Int, rect: CGRect, checkbox: Bool)) -> Bool {
                        fields.contains { $0.page == t.page && ($0.kind == .checkbox) == t.checkbox
                            && (t.rect.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) || $0.rect.contains(CGPoint(x: t.rect.midX, y: t.rect.midY))) }
                    }
                    let found = truth.filter(hit).count
                    let extra = fields.filter { f in !truth.contains { $0.page == f.page && ($0.rect.contains(CGPoint(x: f.rect.midX, y: f.rect.midY)) || f.rect.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY))) } }.count
                    print("real fields: \(truth.count) (\(truth.filter(\.checkbox).count) checkboxes), found: \(found) (\(Int(Double(found) / Double(truth.count) * 100))%), extra: \(extra)")
                    for t in truth where !hit(t) { print("  missed p\(t.page + 1) \(t.checkbox ? "checkbox" : "text") \(t.rect.integral)") }
                }
                if args.count > 2 {
                    FormDetector.addFields(fields, to: doc)
                    try doc.dataRepresentation()?.write(to: URL(fileURLWithPath: args[2]))
                }
            case "templates":
                // Renders every template to a folder (and fills a couple of fields in the invoice).
                let dir = URL(fileURLWithPath: args[1])
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for t in DocTemplate.all {
                    let values = t.id == "invoice" ? ["invoice_number": "INV-0042", "from_name": "Northwind Design", "item1_description": "Logo design", "total_due": "1,200.00", "rsvp_i_will_attend": "yes"] : [:]
                    let data = try await TemplateRenderer.render(t, values: values)
                    try data.write(to: dir.appendingPathComponent("\(t.id).pdf"))
                    let d = PDFDocument(data: data)!
                    let fields = (0..<d.pageCount).reduce(0) { $0 + (d.page(at: $1)?.annotations.filter { $0.type == "Widget" }.count ?? 0) }
                    print(String(format: "%-20@ pages %d fields %3d / %3d", t.id as NSString, d.pageCount, fields, t.fieldNames.count))
                }
            case "logo":
                // ezpdf-cli logo "<prompt>" <out-dir> [model-id]
                let model = ImageGen.models.first { $0.id == (args.count > 3 ? args[3] : "apple") } ?? ImageGen.models[0]
                let t0 = Date()
                let imgs = try await ImageGen.generate(prompt: ImageGen.prompt(args[1], style: .minimal), model: model, count: 1)
                for (i, d) in imgs.enumerated() {
                    try d.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent("logo\(i).png"))
                    if let cut = try? await ImageGen.removeBackground(d) { try cut.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent("logo\(i)-cut.png")) }
                }
                print("images:", imgs.count, "secs:", Int(Date().timeIntervalSince(t0)))
            case "cutout":
                try await ImageGen.removeBackground(Data(contentsOf: URL(fileURLWithPath: args[1]))).write(to: URL(fileURLWithPath: args[2]))
                print("ok")
            case "lines":
                guard let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { return 2 }
                for l in await PageText.lines(doc) {
                    print(String(format: "p%d y%5.1f h%4.1f | ", l.page, l.y, l.height) + l.cells.map { "[\($0.text) @\(Int($0.rect.minX))-\(Int($0.rect.maxX))]" }.joined(separator: " "))
                }
            case "serve":
                let port = args.count > 1 ? UInt16(args[1]) ?? LocalServer.defaultPort : LocalServer.defaultPort
                LocalServer.shared.start(port: port)
                print("ezpdf MCP on http://127.0.0.1:\(port)/mcp  token file: \(LocalServer.tokenFile.path)")
                _ = LocalServer.token
                while true { try await Task.sleep(for: .seconds(3600)) }
            default:
                usage(); return 2
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func usage() {
        fputs("""
        usage:
          ezpdf-cli web <url> <out.pdf> [preset]       link → PDF (+ EPUB next to it)
          ezpdf-cli file <in...> <out.pdf>             files → PDF
          ezpdf-cli extract <in.pdf> [auto|statement|invoice|tables] [noai]
          ezpdf-cli serve [port]                       run the MCP + extension server

        """, stderr)
    }
}
