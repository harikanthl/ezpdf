//
//  AssistantPanel.swift
//  ezpdf (adapted from ezRecord's Editor/ChatPanel.swift and its home composer mic)
//
//  The assistant beside the reader: ask in words or by voice ("change the total to $3,900 and sign
//  it"). It edits with the same tools agents use; changes wait for Apply unless auto-apply is on.
//  Return sends, Shift-Return adds a line; typing while it works steers it.
//

import SwiftUI
import AVFoundation
import EzPDFCore

struct AssistantPanel: View {
    @Bindable var chat: AssistantModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("ezpdf.settingsTab") private var settingsTab = "general"
    @FocusState private var focused: Bool

    static let suggestions = [
        "Fix any typos on this page",
        "Change the date to today",
        "Sign it as my name at the signature line",
        "Redact my account numbers",
        "Fill in the form with my details",
        "Summarize this in three bullets",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            if let mark = chat.mark { markChip(mark) }
            if let voiceProblem = chat.voiceProblem {
                Text(voiceProblem).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            composer
        }
        .background(.background)
        .onDisappear { chat.dictation.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text("Assistant").font(.headline)
            Spacer()
            if !chat.items.isEmpty {
                Button { chat.clear() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(IconButtonStyle()).help("New conversation")
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.items.isEmpty { emptyState }
                    ForEach(chat.items) { item in
                        AssistantRow(item: item, chat: chat).id(item.id)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
                    }
                    if chat.isWorking, !chat.isWaitingForUser {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working…").font(.caption).foregroundStyle(.secondary) }
                            .id("working")
                    }
                }
                .padding(12)
                .animation(reduceMotion ? nil : Motion.out, value: chat.items.count)
            }
            .onChange(of: chat.items.count) {
                if let last = chat.items.last { withAnimation(Motion.out) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tell me what to change. I can edit words, add text, sign, fill forms, redact, rearrange pages and more. Every change can be undone.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Self.suggestions, id: \.self) { s in
                Button { chat.send(s) } label: {
                    Text(s).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
                }
                .buttonStyle(PressStyleLight())
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Ask for an edit…", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .frame(minHeight: 44, alignment: .topLeading)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { chat.draft += "\n" } else { send() }
                    return .handled
                }
            HStack(spacing: 6) {
                modelMenu
                Toggle(isOn: $chat.applyWithoutAsking) {
                    Label("Auto-apply", systemImage: chat.applyWithoutAsking ? "checkmark.circle.fill" : "circle")
                }
                .toggleStyle(.button)
                .buttonStyle(ChipStyle(isOn: chat.applyWithoutAsking))
                .fixedSize()
                .help("Apply changes without asking first (Undo still reverts them)")
                Spacer(minLength: 0)
                Button { chat.toggleListening() } label: {
                    Image(systemName: chat.dictation.isListening ? "waveform" : "mic")
                        .font(.system(size: 12, weight: .semibold))
                        .symbolEffect(.variableColor.iterative, isActive: chat.dictation.isListening)
                }
                .buttonStyle(ChipStyle(isOn: chat.dictation.isListening))
                .help(chat.dictation.isListening ? "Stop talking" : "Talk instead of typing (stays on this Mac)")
                sendButton
            }
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: 1)
        }
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .padding(10)
    }

    @ViewBuilder
    private var sendButton: some View {
        let empty = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if chat.isWorking, empty {
            Button { chat.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary, in: .circle)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
            .buttonStyle(PressStyleLight()).help("Stop")
        } else {
            Button(action: send) {
                Image(systemName: chat.isWorking ? "arrow.turn.down.right" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(empty ? Color.primary.opacity(0.12) : Color.accentColor, in: .circle)
                    .foregroundStyle(empty ? Color.secondary : Color.white)
            }
            .buttonStyle(PressStyleLight())
            .disabled(empty)
            .help(chat.isWorking ? "Tell it while it works" : "Send (Return)")
        }
    }

    private var modelMenu: some View {
        Menu {
            let choices = AssistantModel.ModelChoice.available()
            if choices.isEmpty { Text("Add an API key or turn on Apple Intelligence") }
            ForEach(choices) { c in
                Button { chat.modelChoice = c } label: {
                    if chat.modelTitle == c.title { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                }
            }
            Divider()
            Button("Assistant Settings…") { settingsTab = "assistant"; openSettings() }
        } label: {
            Label(chat.modelTitle, systemImage: "cpu").lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(ChipStyle())
        .fixedSize()
        .help("Which model answers")
    }

    private func send() {
        let text = chat.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.send(text)
        chat.draft = ""
    }

    private func markChip(_ m: AssistantModel.Mark) -> some View {
        HStack(spacing: 8) {
            if let data = m.image, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 44, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "pencil.and.scribble").foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Marked on page \(m.page)").font(.caption.weight(.semibold))
                Text(m.text.isEmpty ? "No text under the marks" : "“\(m.text.prefix(80))”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { withAnimation(Motion.outFast) { chat.mark = nil } } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(IconButtonStyle()).help("Remove the mark")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.1)))
        .padding(.horizontal, 10).padding(.top, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

struct AssistantRow: View {
    let item: AssistantModel.Item
    let chat: AssistantModel

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 30)
                Text(text).textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.16), in: .rect(cornerRadius: 12, style: .continuous))
            }
        case .assistant(let text):
            Text(LocalizedStringKey(text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let title, let detail, let ok):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Group {
                    if let ok { Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? .green : .orange) }
                    else { ProgressView().controlSize(.mini) }
                }
                .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
            }
        case .confirm(let title, let preview):
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "hand.raised").font(.callout.weight(.semibold))
                Text(preview).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Apply") { chat.resolve(allow: true) }.buttonStyle(PressableStyle(prominent: true)).keyboardShortcut(.return, modifiers: .command)
                    Button("Don't") { chat.resolve(allow: false) }.buttonStyle(PressableStyle())
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
        }
    }
}

/// Small capsule chips along the composer's bottom edge.
struct ChipStyle: ButtonStyle {
    var isOn = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).frame(height: 24)
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct PressStyleLight: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}
