import Foundation
import EzPDFCore
import PDFKit

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
