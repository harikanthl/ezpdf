import Foundation

/// A document's earlier and undone versions, for Undo and Redo: `history/undo/` and `history/redo/`
/// in the document's folder, one PDF per step, numbered in order. Every change pushes the version it
/// replaces onto the undo side and clears the redo side, like any editor.
///
/// Kept to `maxSteps` steps and `maxBytes` on disk, oldest dropped first. A document saved by an
/// older ezpdf (a single `document.prev.pdf`) has that file taken in as its one undo step.
struct EditHistory {
    static let maxSteps = 30
    static let maxBytes: Int64 = 500_000_000

    let folder: URL
    var undoDir: URL { folder.appendingPathComponent("history/undo", isDirectory: true) }
    var redoDir: URL { folder.appendingPathComponent("history/redo", isDirectory: true) }

    init(folder: URL) {
        self.folder = folder
        let legacy = folder.appendingPathComponent("document.prev.pdf")
        let fm = FileManager.default
        if fm.fileExists(atPath: legacy.path), steps(undoDir).isEmpty {
            try? fm.createDirectory(at: undoDir, withIntermediateDirectories: true)
            try? fm.moveItem(at: legacy, to: undoDir.appendingPathComponent(Self.name(1)))
        }
    }

    static func name(_ n: Int) -> String { String(format: "%06d.pdf", n) }

    /// Steps oldest first.
    func steps(_ dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pdf" && Int($0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var canUndo: Bool { !steps(undoDir).isEmpty }
    var canRedo: Bool { !steps(redoDir).isEmpty }
    var versions: [URL] { steps(undoDir) + steps(redoDir) }

    /// Copies `file` in as the newest step on one side. Copied to a temporary name first and then
    /// moved, so a half-written step is never seen.
    func push(_ file: URL, to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let next = (steps(dir).last.flatMap { Int($0.deletingPathExtension().lastPathComponent) } ?? 0) + 1
        let staging = dir.appendingPathComponent(".staging-\(UUID().uuidString).pdf")
        try fm.copyItem(at: file, to: staging)
        do { try fm.moveItem(at: staging, to: dir.appendingPathComponent(Self.name(next))) }
        catch { try? fm.removeItem(at: staging); throw error }
    }

    /// The newest step on one side (not removed yet: the caller removes it once it's been used).
    func newest(_ dir: URL) -> URL? { steps(dir).last }

    func clearRedo() {
        for f in steps(redoDir) { try? FileManager.default.removeItem(at: f) }
    }

    /// Drops the oldest undo steps past the step and size limits.
    func trim() {
        var list = steps(undoDir)
        let size: (URL) -> Int64 = { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var total = (list + steps(redoDir)).reduce(Int64(0)) { $0 + size($1) }
        while let oldest = list.first, list.count > Self.maxSteps || total > Self.maxBytes && list.count > 1 {
            total -= size(oldest)
            try? FileManager.default.removeItem(at: oldest)
            list.removeFirst()
        }
    }
}
