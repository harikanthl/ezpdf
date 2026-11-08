import Foundation
import AppKit
import PDFKit

/// Renders a DocTemplate to a Letter PDF and turns each blank into a real form field.
@MainActor
public enum TemplateRenderer {
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 48

    static let fieldsJS = """
    const sy = window.scrollY || 0;
    return JSON.stringify(Array.from(document.querySelectorAll('[data-field]')).map(e => {
      const r = e.getBoundingClientRect();
      return { name: e.dataset.field, type: e.dataset.type, x: r.left, y: r.top + sy, w: r.width, h: r.height, label: e.title || '' };
    }));
    """

    struct Box: Decodable { let name: String; let type: String; let x, y, w, h: Double; let label: String }

    public static func render(_ t: DocTemplate, values: [String: String] = [:]) async throws -> Data {
        let width = pageSize.width - margin * 2
        let session = WebSession(width: width, height: pageSize.height - margin * 2, javaScript: false)
        defer { session.close() }
        try await session.loadHTML(t.document(width: width), baseURL: nil)
        let json = try await session.jsString(fieldsJS)
        let boxes = (try? JSONDecoder().decode([Box].self, from: Data(json.utf8))) ?? []
        let r = try await PageLayout.renderPDF(session: session, pageSize: pageSize, margin: margin, contentWidth: width,
                                               metadata: .init(title: t.name, author: nil, subject: "ezpdf template"))
        guard let doc = PDFDocument(data: r.pdf) else { throw EzPDFError.failed("Couldn't build the template.") }
        var seen = Set<String>()
        for b in boxes {
            guard let i = r.slices.firstIndex(where: { $0.contains(b.y + b.h / 2) }), let page = doc.page(at: i), seen.insert(b.name).inserted else { continue }
            let top = CGFloat(b.y - r.slices[i].lowerBound) + margin
            let rect = CGRect(x: margin + CGFloat(b.x), y: pageSize.height - top - CGFloat(b.h), width: CGFloat(b.w), height: CGFloat(b.h))
            let w = PDFAnnotation(bounds: rect.insetBy(dx: 0, dy: b.type == "checkbox" ? 0 : 1), forType: .widget, withProperties: nil)
            w.fieldName = b.name
            if !b.label.isEmpty { w.setValue(b.label, forAnnotationKey: PDFAnnotationKey(rawValue: "/TU")) }
            if b.type == "checkbox" {
                w.widgetFieldType = .button
                w.widgetControlType = .checkBoxControl
                w.buttonWidgetState = ["true", "yes", "on", "x"].contains(values[b.name]?.lowercased() ?? "") ? .onState : .offState
            } else {
                w.widgetFieldType = .text
                w.isMultiline = b.type == "multiline"
                w.font = NSFont.systemFont(ofSize: b.type == "multiline" ? 9.5 : 10)
                w.fontColor = .black
                w.widgetStringValue = values[b.name] ?? ""
                if b.type == "money" || b.type == "number" { w.alignment = .right }
            }
            w.backgroundColor = NSColor(calibratedRed: 0.93, green: 0.95, blue: 1.0, alpha: 0.35)
            let border = PDFBorder(); border.lineWidth = 0
            w.border = border
            page.addAnnotation(w)
        }
        guard let out = doc.dataRepresentation() else { throw EzPDFError.failed("Couldn't build the template.") }
        return out
    }
}
