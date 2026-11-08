import SwiftUI
import PDFKit
import EzPDFCore
import UniformTypeIdentifiers

/// Page organizer: select pages (click, ⌘-click, ⇧-click), drag to reorder, rotate, delete,
/// extract or split. Every action goes through EzPDF ops, so it's undoable and agent-equivalent.
struct PagesView: View {
    let record: DocumentRecord
    /// Saves pending reader changes (highlights) before a page edit, so neither overwrites the other.
    var beforeEdit: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var thumbs: [Int: NSImage] = [:]
    @State private var count = 0
    @State private var selected: Set<Int> = []
    @State private var anchor: Int?
    @State private var dropTarget: Int?
    @FocusState private var gridFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(0..<count, id: \.self) { i in
                        pageCell(i)
                    }
                    if count > 0 { endDropZone }
                }
                .padding(22)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onTapGesture { selected = []; gridFocused = true }
            // Keys act on pages only while the grid has focus, never while typing in a field.
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onDeleteCommand { if gridFocused { run(.delete) } }
            .onKeyPress(characters: ["a"], phases: .down) { press in
                guard gridFocused, press.modifiers == .command else { return .ignored }
                selected = Set(0..<count)
                return .handled
            }
        }
        .task(id: "\(record.id)-\(record.modifiedAt.timeIntervalSince1970)") { await loadThumbs() }
    }

    /// Drop target after the last page, so pages can be moved to the end.
    private var endDropZone: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(dropTarget == count ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .frame(height: 170)
            .overlay(Text("Move to end").font(.caption).foregroundStyle(.secondary))
            .padding(5)
            .dropDestination(for: String.self) { items, _ in
                guard let from = items.first.flatMap(Int.init) else { return false }
                return move(from: from, to: count)
            } isTargeted: { over in
                withAnimation(reduceMotion ? nil : Motion.outFast) { dropTarget = over ? count : (dropTarget == count ? nil : dropTarget) }
            }
    }

    private var spec: String { selected.sorted().map { "\($0 + 1)" }.joined(separator: ",") }

    private var actionBar: some View {
        HStack(spacing: 6) {
            Text(selected.isEmpty ? "\(count) pages" : "\(selected.count) selected")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Spacer()
            Group {
                Button { run(.rotate, degrees: 270) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                Button { run(.rotate, degrees: 90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                Button { run(.duplicate) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button { run(.extract) } label: { Label("Extract to New", systemImage: "doc.on.doc") }
                Button(role: .destructive) { run(.delete) } label: { Label("Delete", systemImage: "trash") }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .disabled(selected.isEmpty)
            Divider().frame(height: 18)
            Menu {
                Button("Split Every Page") { split(every: 1) }
                Button("Split Every 10 Pages") { split(every: 10) }
                Button("Split at Selected Pages") { split(starts: selected.sorted().map { $0 + 1 }) }.disabled(selected.isEmpty)
                Divider()
                Button("Insert Blank Page After Selection") { run(.insert_blank) }
                Button("Undo Last Change") { undo() }
            } label: { Image(systemName: "scissors") }
            .menuStyle(.borderlessButton).frame(width: 36)
            .help("Split, insert, undo")
        }
        .padding(.horizontal, 14).frame(height: 38)
    }

    private func pageCell(_ i: Int) -> some View {
        let isSelected = selected.contains(i)
        return VStack(spacing: 6) {
            ZStack {
                if let img = thumbs[i] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(.background).aspectRatio(0.75, contentMode: .fit)
                }
            }
            .frame(height: 170)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
            .overlay(alignment: .leading) {
                if dropTarget == i {
                    Capsule().fill(Color.accentColor).frame(width: 3).offset(x: -10)
                }
            }
            Text("\(i + 1)")
                .font(.caption.monospacedDigit().weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Capsule().fill(isSelected ? Color.accentColor : .clear))
                .foregroundStyle(isSelected ? .white : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.openPage = i + 1 }
        .onTapGesture { click(i); gridFocused = true }
        .draggable("\(i)") {
            Image(nsImage: thumbs[i] ?? NSImage()).resizable().aspectRatio(contentMode: .fit).frame(height: 110).opacity(0.85)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first.flatMap(Int.init) else { return false }
            return move(from: from, to: i)
        } isTargeted: { over in
            withAnimation(reduceMotion ? nil : Motion.outFast) { dropTarget = over ? i : (dropTarget == i ? nil : dropTarget) }
        }
        .contextMenu {
            Button("Open Page") { app.openPage = i + 1 }
            Button("Rotate Right") { selectIfNeeded(i); run(.rotate, degrees: 90) }
            Button("Extract to New Document") { selectIfNeeded(i); run(.extract) }
            Divider()
            Button("Delete", role: .destructive) { selectIfNeeded(i); run(.delete) }
        }
    }

    /// Moves the dragged page (or the selection it belongs to) so it starts before page `target`.
    private func move(from: Int, to target: Int) -> Bool {
        let moving = selected.contains(from) ? selected.sorted() : [from]
        // Position `target` in the original order, counted without the pages being moved.
        let before = moving.filter { $0 < target }.count
        let newStart = target - before
        // Dropping a block where it already is changes nothing; don't spend the undo on it.
        if moving == Array(newStart..<(newStart + moving.count)) { return false }
        let spec = moving.map { "\($0 + 1)" }.joined(separator: ",")
        perform { try app.ops.pages(record.id, action: .move, pages: spec, to: newStart + 1) }
        selected = Set(newStart..<(newStart + moving.count))
        anchor = newStart
        return true
    }

    private func selectIfNeeded(_ i: Int) { if !selected.contains(i) { selected = [i] } }

    private func click(_ i: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
            anchor = i
        } else if flags.contains(.shift), let a = anchor {
            selected = Set(min(a, i)...max(a, i))
        } else {
            selected = [i]; anchor = i
        }
    }

    /// Renders thumbnails off the main thread on a private copy of the document, in batches,
    /// stopping as soon as the view moves on.
    private func loadThumbs() async {
        let url = Library.shared.pdfURL(for: record.id)
        guard let doc = PDFDocument(url: url) else { return }
        count = doc.pageCount
        selected = selected.filter { $0 < count }
        var fresh: [Int: NSImage] = [:]
        let total = doc.pageCount
        for start in stride(from: 0, to: total, by: 16) {
            if Task.isCancelled { return }
            let range = start..<min(start + 16, total)
            let batch = await Task.detached(priority: .userInitiated) { () -> [(Int, NSImage)] in
                guard let own = PDFDocument(url: url) else { return [] }
                return range.compactMap { i in
                    own.page(at: i).map { (i, $0.thumbnail(of: NSSize(width: 170, height: 220), for: .cropBox)) }
                }
            }.value
            if Task.isCancelled { return }
            for (i, img) in batch { fresh[i] = img }
            thumbs = fresh
        }
    }

    private func perform(_ body: () throws -> EzPDF.PageResult) {
        beforeEdit()
        do {
            let r = try body()
            if !r.created.isEmpty {
                app.show(r.created.count == 1 ? "Made “\(r.created[0].title)”" : "Made \(r.created.count) documents", documentID: r.created.first?.id)
            }
        } catch { app.show(error.localizedDescription, error: true) }
    }

    private func run(_ action: EzPDF.PageAction, degrees: Int = 90) {
        guard !selected.isEmpty || action == .insert_blank else { return }
        let s = spec
        perform { try app.ops.pages(record.id, action: action, pages: s.isEmpty ? nil : s, degrees: degrees) }
        if action == .delete { selected = [] }
    }

    private func split(every: Int? = nil, starts: [Int]? = nil) {
        perform { try app.ops.pages(record.id, action: .split, every: every, startPages: starts) }
    }

    private func undo() {
        beforeEdit()
        do { _ = try app.ops.undo(record.id) } catch { app.show(error.localizedDescription, error: true) }
    }
}
