import SwiftUI
import PDFKit
import EzPDFCore
import UniformTypeIdentifiers

/// Page organizer: select pages (click, ⌘-click, ⇧-click), drag to reorder, rotate, delete,
/// extract or split. Every action goes through EzPDF ops, so it's undoable and agent-equivalent.
struct PagesView: View {
    let record: DocumentRecord
    var onChange: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var thumbs: [Int: NSImage] = [:]
    @State private var count = 0
    @State private var selected: Set<Int> = []
    @State private var anchor: Int?
    @State private var dropTarget: Int?
    @State private var version = 0

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
                }
                .padding(22)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onTapGesture { selected = [] }
        }
        .task(id: "\(record.id)-\(record.modifiedAt.timeIntervalSince1970)") { await loadThumbs() }
        .background {
            Group {
                Button("") { selected = Set(0..<count) }.keyboardShortcut("a")
                Button("") { run(.delete) }.keyboardShortcut(.delete, modifiers: [])
            }.opacity(0).allowsHitTesting(false)
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
        .onTapGesture { click(i) }
        .onTapGesture(count: 2) { app.openPage = i + 1 }
        .draggable("\(i)") {
            Image(nsImage: thumbs[i] ?? NSImage()).resizable().aspectRatio(contentMode: .fit).frame(height: 110).opacity(0.85)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first.flatMap(Int.init) else { return false }
            let moving = selected.contains(from) ? selected.sorted() : [from]
            let spec = moving.map { "\($0 + 1)" }.joined(separator: ",")
            // Position i in the original order becomes this in the order without the moved pages.
            let before = moving.filter { $0 < i }.count
            perform { try app.ops.pages(record.id, action: .move, pages: spec, to: i - before + 1) }
            return true
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

    private func loadThumbs() async {
        guard let doc = PDFDocument(url: Library.shared.pdfURL(for: record.id)) else { return }
        count = doc.pageCount
        selected = selected.filter { $0 < count }
        var fresh: [Int: NSImage] = [:]
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            fresh[i] = page.thumbnail(of: NSSize(width: 260, height: 340), for: .cropBox)
            if i % 12 == 11 { thumbs = fresh; await Task.yield() }
        }
        thumbs = fresh
    }

    private func perform(_ body: () throws -> EzPDF.PageResult) {
        do {
            let r = try body()
            if !r.created.isEmpty {
                app.show(r.created.count == 1 ? "Made “\(r.created[0].title)”" : "Made \(r.created.count) documents", documentID: r.created.first?.id)
            }
            onChange()
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
        do { _ = try app.ops.undo(record.id); onChange() } catch { app.show(error.localizedDescription, error: true) }
    }
}
