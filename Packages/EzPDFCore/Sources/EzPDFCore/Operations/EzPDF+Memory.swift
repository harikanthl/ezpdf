import Foundation

// MARK: Memory

/// What the assistant knows about the person across conversations (after ezRecord's CreatorMemory):
/// short notes they asked it to remember, or that it saved when they said something worth keeping
/// ("sign as Hari L.", "dates as 12/10/2026", "my company is Northwind Design"). Kept in the library
/// folder, read into every request's instructions. Nothing leaves the Mac except with the request to
/// the model the person chose.
public struct MemoryNote: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var text: String
    public var createdAt: Date
    /// Who saved it: "you", "assistant", or an agent's name.
    public var source: String
}

extension EzPDF {
    static let memoryLimit = 200
    static let memoryNoteLength = 300

    var memoryURL: URL { library.root.appendingPathComponent(".memory.json") }

    public func memory() -> [MemoryNote] {
        guard let d = try? Data(contentsOf: memoryURL) else { return [] }
        return (try? JSONDecoder.ezpdf.decode([MemoryNote].self, from: d)) ?? []
    }

    private func saveMemory(_ notes: [MemoryNote]) throws {
        try JSONEncoder.ezpdf.encode(notes).write(to: memoryURL, options: .atomic)
    }

    /// Remembers a note (the same note twice is kept once). The oldest go past 200 notes.
    @discardableResult
    public func remember(_ text: String, source: String) throws -> MemoryNote {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !t.isEmpty else { throw EzPDFError.invalidInput("Say what to remember.") }
        guard t.count <= Self.memoryNoteLength else { throw EzPDFError.invalidInput("Keep it under \(Self.memoryNoteLength) characters.") }
        var notes = memory()
        if let same = notes.first(where: { $0.text.caseInsensitiveCompare(t) == .orderedSame }) { return same }
        let note = MemoryNote(id: Library.newID(), text: t, createdAt: Date(), source: source)
        notes.append(note)
        if notes.count > Self.memoryLimit { notes.removeFirst(notes.count - Self.memoryLimit) }
        try saveMemory(notes)
        return note
    }

    /// Forgets notes by id, or every note containing `matching` (case-insensitive). Returns what was removed.
    @discardableResult
    public func forget(id: String? = nil, matching: String? = nil) throws -> [MemoryNote] {
        var notes = memory()
        let gone = notes.filter { n in
            if let id { return n.id == id }
            if let m = matching?.trimmingCharacters(in: .whitespaces), !m.isEmpty { return n.text.localizedCaseInsensitiveContains(m) }
            return false
        }
        guard !gone.isEmpty else { throw EzPDFError.invalidInput("No remembered note like that.") }
        notes.removeAll { n in gone.contains { $0.id == n.id } }
        try saveMemory(notes)
        return gone
    }

    /// What goes into the assistant's instructions: the notes (newest first) and settings it should
    /// know, within `limit` characters.
    public func memorySummary(limit: Int = 1500) -> String {
        var lines: [String] = []
        if let name = UserDefaults.standard.string(forKey: "ezpdf.signatureName"), !name.isEmpty {
            lines.append("Signs documents as “\(name)”.")
        }
        for n in memory().reversed() { lines.append(n.text) }
        var out: [String] = []
        var used = 0
        for l in lines {
            guard used + l.count + 3 <= limit else { break }
            out.append("- " + l)
            used += l.count + 3
        }
        return out.isEmpty ? "" : "What you know about the person (from earlier conversations; use it, don't repeat it back):\n" + out.joined(separator: "\n")
    }
}

// MARK: Decision log

/// One change to a document: who made it, what it was, and how it went. Kept per document in
/// `history.jsonl` (newest last), for the person to look back on and for agents to check what happened.
public struct DocumentEvent: Codable, Sendable, Identifiable {
    public var id: String
    public var at: Date
    /// "You", "ezpdf assistant", or the agent's name.
    public var by: String
    /// What it was: a tool's title ("Change text"), or "Undo", "Redo", "Edit".
    public var action: String
    /// The request in a line or two (arguments, shortened; no images or passwords).
    public var detail: String
    public var ok: Bool
    /// What came of it, shortened.
    public var result: String
}

extension EzPDF {
    /// Who is changing documents, and with what, for the decision log. Tool runs set it around their work.
    public struct Actor: Sendable {
        public var by: String
        public var action: String
        public var detail: String
        public init(by: String, action: String, detail: String) { self.by = by; self.action = action; self.detail = detail }
    }

    @TaskLocal public static var actor: Actor?

    static let historyMaxLines = 2000

    func historyURL(_ id: String) -> URL { library.folder(for: id).appendingPathComponent("history.jsonl") }

    /// Adds an event to a document's log. The log keeps its newest 2000 events.
    func log(_ id: String, by: String, action: String, detail: String, ok: Bool, result: String) {
        let event = DocumentEvent(id: Library.newID(), at: Date(), by: String(by.prefix(80)), action: String(action.prefix(80)),
                                  detail: String(detail.prefix(400)), ok: ok, result: String(result.prefix(300)))
        // One event per line: a compact encoder (the library's pretty-prints across lines).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let line = try? encoder.encode(event) else { return }
        let url = historyURL(id)
        var data = (try? Data(contentsOf: url)) ?? Data()
        data.append(line)
        data.append(0x0A)
        // Past the limit, keep the newest lines.
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if lines.count > Self.historyMaxLines {
            data = Data(lines.suffix(Self.historyMaxLines).joined(separator: [0x0A])) + Data([0x0A])
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Logs a change made by whoever `EzPDF.actor` names (you, when nothing does).
    func logChange(_ id: String, fallback action: String) {
        let a = Self.actor
        log(id, by: a?.by ?? "You", action: a?.action ?? action, detail: a?.detail ?? "", ok: true, result: "")
    }

    /// A document's events, newest first.
    public func history(_ id: String, limit: Int = 100) throws -> [DocumentEvent] {
        let rec = try record(id)
        guard let data = try? Data(contentsOf: historyURL(rec.id)) else { return [] }
        let events = data.split(separator: 0x0A).compactMap { try? JSONDecoder.ezpdf.decode(DocumentEvent.self, from: Data($0)) }
        return Array(events.reversed().prefix(limit))
    }
}
