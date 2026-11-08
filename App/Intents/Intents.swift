import AppIntents
import EzPDFCore
import UniformTypeIdentifiers

/// Shortcuts / Spotlight / Siri actions. Same operations as the UI and the MCP server.

enum PresetEntity: String, AppEnum {
    case kindle, kindleScribe, phone, letter, a4, web
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Page Size"
    static let caseDisplayRepresentations: [PresetEntity: DisplayRepresentation] = [
        .kindle: "Kindle", .kindleScribe: "Kindle Scribe", .phone: "Phone", .letter: "Letter", .a4: "A4", .web: "As on the Web",
    ]
    var preset: PagePreset { PagePreset(rawValue: rawValue) ?? .kindle }
}

enum DataKindEntity: String, AppEnum {
    case auto, statement, invoice, tables
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Data Type"
    static let caseDisplayRepresentations: [DataKindEntity: DisplayRepresentation] = [
        .auto: "Automatic", .statement: "Bank Statement", .invoice: "Invoice or Receipt", .tables: "Tables",
    ]
}

enum SheetFormatEntity: String, AppEnum {
    case xlsx, csv
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Spreadsheet Format"
    static let caseDisplayRepresentations: [SheetFormatEntity: DisplayRepresentation] = [.xlsx: "Excel", .csv: "CSV"]
}

struct MakePDFFromLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Make PDF from Link"
    static let description = IntentDescription("Turns a web page into a clean PDF (and EPUB) in ezpdf.")

    @Parameter(title: "Link") var url: URL
    @Parameter(title: "Page Size", default: .kindle) var preset: PresetEntity
    @Parameter(title: "Send to Kindle", default: false) var sendToKindle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Make a \(\.$preset) PDF from \(\.$url)") { \.$sendToKindle }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let rec = try await EzPDF.shared.convert(url: url, preset: preset.preset, source: .shortcut)
        if sendToKindle { _ = try await EzPDF.shared.sendToKindle(rec.id) }
        return .result(value: try IntentOutput.pdf(rec))
    }
}

struct MakePDFFromFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Make PDF from Files"
    static let description = IntentDescription("Combines images, Word, Markdown, text and other files into one PDF.")

    @Parameter(title: "Files", supportedContentTypes: [.item]) var files: [IntentFile]
    @Parameter(title: "Page Size", default: .letter) var preset: PresetEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-intent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = try files.enumerated().map { i, f -> URL in
            // Only the name part: a Shortcut-supplied "../x" can't write outside the temp folder.
            let name = (f.filename as NSString).lastPathComponent
            let u = dir.appendingPathComponent(String(format: "%03d ", i) + (name.isEmpty || name.hasPrefix(".") ? "file" : name))
            try f.data.write(to: u)
            return u
        }
        let rec = try await EzPDF.shared.convert(files: urls, preset: preset.preset, source: .shortcut)
        return .result(value: try IntentOutput.pdf(rec))
    }
}

struct ExtractDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract Statement or Invoice Data"
    static let description = IntentDescription("Reads a bank statement, invoice or table PDF on this Mac and returns a spreadsheet.")

    @Parameter(title: "PDF", supportedContentTypes: [.pdf]) var file: IntentFile
    @Parameter(title: "Type", default: .auto) var kind: DataKindEntity
    @Parameter(title: "Format", default: .xlsx) var format: SheetFormatEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let name = (file.filename as NSString).lastPathComponent
        let rec = try await EzPDF.shared.convert(data: file.data, fileName: name.lowercased().hasSuffix(".pdf") ? name : name + ".pdf", source: .shortcut)
        let result = try await EzPDF.shared.extract(rec.id, kind: ExtractKind.parse(kind.rawValue), source: .shortcut)
        let url = try EzPDF.shared.saveExtraction(result, for: rec.id, format: format == .csv ? .csv : .xlsx)
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: format == .csv ? .commaSeparatedText : UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data))
    }
}

struct SendLinkToKindleIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Link to Kindle"
    static let description = IntentDescription("Makes a clean EPUB/PDF from a web page and emails it to your Kindle.")

    @Parameter(title: "Link") var url: URL

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rec = try await EzPDF.shared.convert(url: url, preset: .kindle, format: .both, source: .shortcut)
        let r = try await EzPDF.shared.sendToKindle(rec.id)
        return .result(dialog: "Sent “\(rec.title)” to your Kindle as \(r.format.rawValue.uppercased()).")
    }
}

/// Files handed to Shortcuts are copies, so later actions can't change the library's own file.
enum IntentOutput {
    @MainActor
    static func pdf(_ rec: DocumentRecord) throws -> IntentFile {
        var name = rec.title.replacingOccurrences(of: "[/:\\\\?%*|\"<>\\p{Cc}]", with: " ", options: .regularExpression)
        name = String(name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))).prefix(90))
        if name.isEmpty { name = "Document" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ezpdf-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("\(name).pdf")
        try FileManager.default.copyItem(at: Library.shared.pdfURL(for: rec.id), to: copy)
        return IntentFile(fileURL: copy, filename: copy.lastPathComponent, type: .pdf)
    }
}

struct EzPDFShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendLinkToKindleIntent(), phrases: ["Send to Kindle with \(.applicationName)", "\(.applicationName) send to Kindle"],
                    shortTitle: "Send Link to Kindle", systemImageName: "paperplane")
        AppShortcut(intent: MakePDFFromLinkIntent(), phrases: ["Make a PDF with \(.applicationName)", "\(.applicationName) this page"],
                    shortTitle: "Make PDF from Link", systemImageName: "doc.badge.plus")
        AppShortcut(intent: ExtractDataIntent(), phrases: ["Extract statement with \(.applicationName)", "Read invoice with \(.applicationName)"],
                    shortTitle: "Extract Data", systemImageName: "tablecells")
        AppShortcut(intent: MakePDFFromFilesIntent(), phrases: ["Combine files with \(.applicationName)"],
                    shortTitle: "Make PDF from Files", systemImageName: "square.stack")
    }
}
