import SwiftUI
import EzPDFCore
import UniformTypeIdentifiers

/// Direct editing tools in the reader: pick a tool, drag a box on the page, fill in the details.
enum EditTool: String, CaseIterable, Identifiable {
    case text = "Add Text", signature = "Sign", image = "Add Image", box = "Draw Box", whiteout = "White-out", redact = "Redact Area"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .text: return "textformat"
        case .signature: return "signature"
        case .image: return "photo"
        case .box: return "rectangle"
        case .whiteout: return "eraser"
        case .redact: return "rectangle.fill"
        }
    }
    var hint: String {
        switch self {
        case .text: return "Drag where the text should go."
        case .signature: return "Drag over the signature line."
        case .image: return "Drag where the image should go."
        case .box: return "Drag to draw a box."
        case .whiteout: return "Drag over what to cover."
        case .redact: return "Drag over what to remove for good."
        }
    }
}

/// Captures a drag over the PDF and reports the rectangle (view coordinates, origin top-left).
struct PlacementOverlay: View {
    let tool: EditTool
    var onRect: (CGRect) -> Void
    var onCancel: () -> Void
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)          // catches the mouse everywhere
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in if start == nil { start = v.startLocation }; current = v.location }
                    .onEnded { v in
                        let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                       width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                        start = nil; current = nil
                        if r.width > 6, r.height > 6 { onRect(r) }
                    })
            if let start, let current {
                let r = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
                Rectangle()
                    .fill(tool == .redact ? Color.black.opacity(0.35) : Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 8) {
                Image(systemName: tool.symbol)
                Text(tool.hint)
                Button("Cancel", action: onCancel).buttonStyle(PressableStyle()).keyboardShortcut(.escape, modifiers: [])
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 10)
        }
    }
}

/// What a placed tool needs: the words, a name to sign, an image, a font size.
struct PlacementSheet: View {
    let tool: EditTool
    var onDone: (_ text: String, _ fontSize: Int, _ color: String, _ image: Data?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var fontSize = 12
    @State private var color = "black"
    @State private var image: Data?
    @State private var choosingImage = false
    @AppStorage("ezpdf.signatureName") private var signatureName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tool.rawValue, systemImage: tool.symbol).font(.headline)
            switch tool {
            case .text:
                TextField("Text", text: $text, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder).frame(width: 360)
                HStack {
                    Stepper("Size \(fontSize) pt", value: $fontSize, in: 6...72)
                    Picker("", selection: $color) {
                        ForEach(["black", "navy", "blue", "red", "green", "gray"], id: \.self) { Text($0.capitalized).tag($0) }
                    }.labelsHidden().fixedSize()
                }
            case .signature:
                TextField("Your name", text: $text).textFieldStyle(.roundedBorder).frame(width: 360)
                if !text.isEmpty {
                    Text(text).font(.custom("SignPainter-HouseScript", size: 34)).foregroundStyle(Color(red: 0.05, green: 0.1, blue: 0.35))
                }
                Button("Use an Image of My Signature…") { choosingImage = true }.buttonStyle(PressableStyle())
                if image != nil { Label("Signature image ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
            case .image:
                Button(image == nil ? "Choose Image…" : "Choose Another…") { choosingImage = true }.buttonStyle(PressableStyle())
                if image != nil { Label("Image ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
            default:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PressableStyle()).keyboardShortcut(.cancelAction)
                Button("Add") {
                    if tool == .signature, !text.isEmpty { signatureName = text }
                    onDone(text, fontSize, color, image); dismiss()
                }
                .buttonStyle(PressableStyle(prominent: true)).keyboardShortcut(.defaultAction)
                .disabled((tool == .text && text.isEmpty) || (tool == .image && image == nil) || (tool == .signature && text.isEmpty && image == nil))
            }
        }
        .padding(18)
        .onAppear { if tool == .signature { text = signatureName } }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                image = try? Data(contentsOf: url)
            }
        }
    }
}

/// "Change selected text": the selection, and what it should say instead. Errors show here, and
/// the sheet stays open until the change is made. A change too long for its paragraph in a
/// document made from a web page can be made in the article instead, laying it all out again.
struct ReplaceSheet: View {
    struct Failure {
        var message: String
        /// The article can be laid out again with the change; `replaced` lists page changes that would go.
        var reflow: (replaced: [String], run: (String) async -> String?)?
    }
    let original: String
    var onDone: (String) -> Failure?        // nil when it worked
    @Environment(\.dismiss) private var dismiss
    @State private var replacement = ""
    @State private var failure: Failure?
    @State private var reflowing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Change Text", systemImage: "character.cursor.ibeam").font(.headline)
            Text("“\(original)”").font(.callout).foregroundStyle(.secondary).lineLimit(3)
            TextField("New text", text: $replacement, axis: .vertical).lineLimit(1...6)
                .textFieldStyle(.roundedBorder).frame(width: 380).focused($focused)
            if let failure {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).frame(width: 380, alignment: .leading)
                if let reflow = failure.reflow {
                    Text(reflow.replaced.isEmpty
                         ? "This document was made from a web page: Reflow Article makes the change there and lays the whole article out again, so everything after it moves along."
                         : "This document was made from a web page: Reflow Article makes the change there and lays the whole article out again. It replaces \(reflow.replaced.joined(separator: " and ")) since it was laid out; Undo brings them back.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(width: 380, alignment: .leading)
                }
            }
            Text("Keeps the original font, size and color, and moves the rest of the line along. The old words are taken out of the page. Leave it empty to erase. To remove images or drawings too, use Redact.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(width: 380, alignment: .leading)
            HStack {
                Spacer()
                if reflowing { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.buttonStyle(PressableStyle()).keyboardShortcut(.cancelAction)
                if let reflow = failure?.reflow {
                    Button("Reflow Article") {
                        reflowing = true
                        Task {
                            let message = await reflow.run(replacement)
                            reflowing = false
                            if let message { withAnimation(Motion.outFast) { failure = Failure(message: message, reflow: nil) } } else { dismiss() }
                        }
                    }
                    .buttonStyle(PressableStyle()).disabled(reflowing)
                }
                Button("Change") {
                    if let f = onDone(replacement) { withAnimation(Motion.outFast) { failure = f } } else { dismiss() }
                }
                .buttonStyle(PressableStyle(prominent: true)).keyboardShortcut(.defaultAction)
                .disabled(replacement == original || reflowing)
            }
        }
        .padding(18)
        .onAppear { replacement = original; focused = true }
    }
}

/// Editing a placed object: its words, font, size and color, or deleting it.
struct ObjectEditSheet: View {
    struct Model: Identifiable {
        let id: String
        var isText: Bool
        var text: String
        var font: String
        var size: Double
        var color: Color
    }
    @State var model: Model
    var onSave: (Model) -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    static let fonts: [(String, String)] = [
        ("System", ".AppleSystemUIFont"), ("Helvetica Neue", "HelveticaNeue"), ("Avenir Next", "AvenirNext-Regular"),
        ("Times New Roman", "TimesNewRomanPSMT"), ("Georgia", "Georgia"), ("Courier", "Courier"), ("Menlo", "Menlo-Regular"),
        ("Signature", "SignPainter-HouseScript"), ("Script", "SnellRoundhand"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isText ? "Edit Text" : "Edit Object").font(.headline)
            if model.isText {
                TextField("Text", text: $model.text, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder).frame(width: 380)
                HStack {
                    Picker("Font", selection: $model.font) {
                        ForEach(Self.fonts, id: \.1) { name, ps in Text(name).font(.custom(ps, size: 13)).tag(ps) }
                    }
                    .frame(width: 220)
                    Stepper("\(Int(model.size)) pt", value: $model.size, in: 6...120)
                }
                Text(model.text.isEmpty ? "Preview" : model.text)
                    .font(.custom(model.font, size: min(model.size, 40)))
                    .foregroundStyle(model.color)
                    .lineLimit(2)
            }
            ColorPicker("Color", selection: $model.color, supportsOpacity: false)
            Text("Drag to move, drag the corner dot to resize, arrow keys nudge, Delete removes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Delete", role: .destructive) { onDelete(); dismiss() }.buttonStyle(PressableStyle())
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PressableStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(model); dismiss() }.buttonStyle(PressableStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

/// Mark & Talk: draw on the page (circle a word, underline a line, scribble over a box) while you
/// say what to change. Strokes stay until the message is sent.
struct MarkOverlay: View {
    @Binding var strokes: [ReaderController.PenStroke]
    /// Pins a finished stroke (view coordinates) to its page, and maps a pinned one back to the view.
    var anchor: ([CGPoint]) -> ReaderController.PenStroke?
    var toView: (ReaderController.PenStroke) -> [CGPoint]
    /// Changes on scroll and zoom, so the pinned strokes redraw where their page is now.
    var viewport: Int
    var onStrokeEnded: () -> Void
    var onDone: () -> Void
    @State private var current: [CGPoint] = []

    var body: some View {
        ZStack(alignment: .top) {
            Canvas { ctx, _ in
                _ = viewport
                for s in strokes.map(toView) + [current] where s.count > 1 {
                    var p = Path()
                    p.addLines(s)
                    ctx.stroke(p, with: .color(.red.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in current.append(v.location) }
                .onEnded { _ in
                    if let s = anchor(current) { strokes.append(s) }
                    current = []
                    onStrokeEnded()
                })
            HStack(spacing: 8) {
                Image(systemName: "pencil.and.scribble")
                Text("Mark what to change, and say it")
                if !strokes.isEmpty {
                    Button("Clear") { strokes = []; onStrokeEnded() }.buttonStyle(PressableStyle())
                }
                Button("Done", action: onDone).buttonStyle(PressableStyle(prominent: true)).keyboardShortcut(.escape, modifiers: [])
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 10)
        }
    }
}
