import SwiftUI
import EzPDFCore

/// Statement → transactions, invoice → fields + line items, anything → tables. Shows the checks
/// (balance reconciliation, totals) before you export, so wrong numbers don't travel silently.
struct ExtractSheet: View {
    let record: DocumentRecord
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ExtractKind = .auto
    @State private var result: ExtractionResult?
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extract data").font(.title3.weight(.semibold))
                    Text(record.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Picker("", selection: $kind) {
                    Text("Automatic").tag(ExtractKind.auto)
                    Text("Statement").tag(ExtractKind.statement)
                    Text("Invoice").tag(ExtractKind.invoice)
                    Text("Tables").tag(ExtractKind.tables)
                }
                .pickerStyle(.segmented).frame(width: 340)
            }

            Group {
                if running {
                    VStack(spacing: 10) { ProgressView(); Text("Reading the pages…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Couldn't read it", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if let result {
                    content(result)
                }
            }
            .frame(minHeight: 340)
            .transition(.opacity)

            HStack {
                if let r = result, let method = r.statement?.method ?? r.invoice?.method {
                    Label(method.contains("apple") ? "Read on this Mac with Apple Intelligence" : "Read from the page layout, on this Mac",
                          systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { copy() }.buttonStyle(PressableStyle()).disabled(result == nil)
                Button("Save CSV") { save(.csv) }.buttonStyle(PressableStyle()).disabled(result == nil)
                Button("Save Excel") { save(.xlsx) }.buttonStyle(PressableStyle(prominent: true)).disabled(result == nil)
                    .keyboardShortcut(.defaultAction)
                Button("Done") { dismiss() }.buttonStyle(PressableStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 820, height: 560)
        .task(id: kind) { await run() }
    }

    private func run() async {
        withAnimation(Motion.outFast) { running = true; error = nil }
        do {
            let r = try await app.ops.extract(record.id, kind: kind)
            withAnimation(Motion.out) { result = r; running = false }
        } catch {
            withAnimation(Motion.out) { self.error = error.localizedDescription; running = false }
        }
    }

    @ViewBuilder
    private func content(_ r: ExtractionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            summary(r)
            let rows = r.kind == .invoice ? [InvoiceResult.itemHeader] + (r.invoice?.itemRows ?? []) : r.csvRows
            if rows.count > 1 {
                DataTable(rows: rows)
            } else if r.kind != .invoice {
                ContentUnavailableView("Nothing found", systemImage: "tablecells", description: Text("Try another type above."))
            }
        }
    }

    @ViewBuilder
    private func summary(_ r: ExtractionResult) -> some View {
        switch r.kind {
        case .statement:
            let s = r.statement!
            HStack(spacing: 10) {
                Stat(label: "Transactions", value: "\(s.transactions.count)")
                Stat(label: "Money in", value: money(s.totalIn, s.currency))
                Stat(label: "Money out", value: money(s.totalOut, s.currency))
                if let o = s.openingBalance { Stat(label: "Opening", value: money(o, s.currency)) }
                if let c = s.closingBalance { Stat(label: "Closing", value: money(c, s.currency)) }
                if let share = s.reconciledShare {
                    Stat(label: "Balance check", value: "\(Int(share * 100))%", good: share >= 0.99)
                }
            }
            warnings(s.warnings)
        case .invoice:
            let i = r.invoice!
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                ForEach(Array(i.fieldRows.dropFirst().filter { !$0[1].isEmpty }.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row[0]).foregroundStyle(.secondary)
                        Text(row[1]).textSelection(.enabled).fontWeight(row[0].hasPrefix("Total") || row[0] == "Amount due" ? .semibold : .regular)
                    }
                }
            }
            .font(.callout)
            warnings(i.warnings)
        default:
            Text("\(r.tables?.count ?? 0) tables found").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func warnings(_ w: [String]) -> some View {
        ForEach(w, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
    }

    private func money(_ v: Double, _ currency: String?) -> String {
        v.formatted(.currency(code: currency ?? "USD").precision(.fractionLength(2)))
    }

    private func save(_ f: EzPDF.DataFormat) {
        guard let result else { return }
        do {
            let url = try app.ops.saveExtraction(result, for: record.id, format: f)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { app.show(error.localizedDescription, error: true) }
    }

    private func copy() {
        guard let result else { return }
        let tsv = result.csvRows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tsv, forType: .string)
        app.show("Copied. Paste it into Numbers or Excel")
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var good: Bool? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if let good { Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(good ? .green : .orange) }
                Text(value).font(.callout.weight(.semibold).monospacedDigit())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

/// A read-only grid of string rows (first row is the header).
struct DataTable: View {
    struct Row: Identifiable { let id: Int; let cells: [String] }
    let rows: [[String]]

    var body: some View {
        let header = rows.first ?? []
        let body = rows.dropFirst().enumerated().map { Row(id: $0.offset, cells: $0.element) }
        Table(body) {
            TableColumnForEach(0..<header.count, id: \.self) { c in
                TableColumn(header[c].isEmpty ? " " : header[c]) { (row: Row) in
                    let v = c < row.cells.count ? row.cells[c] : ""
                    Text(v)
                        .font(Double(v) != nil ? .callout.monospacedDigit() : .callout)
                        .foregroundStyle(v.hasPrefix("-") ? Color.primary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: Double(v) != nil ? .trailing : .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}
