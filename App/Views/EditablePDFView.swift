import AppKit
import PDFKit
import EzPDFCore

/// PDFView that lets you work with placed objects (text boxes, signatures, images, boxes):
/// click selects, drag moves, the corner handle resizes, arrow keys nudge, Delete removes,
/// double-click edits. Everything else (text selection, links, forms) behaves as usual.
final class EditablePDFView: PDFView {
    private(set) var selectedObject: PDFAnnotation?
    private(set) weak var selectedPage: PDFPage?
    var onCommit: ((PDFAnnotation, PDFPage) -> Void)?
    var onDelete: ((PDFAnnotation, PDFPage) -> Void)?
    var onEdit: ((PDFAnnotation, PDFPage) -> Void)?

    private var dragStart: CGPoint?
    private var startBounds: CGRect?
    private var resizing = false
    private var moved = false
    private static let handle: CGFloat = 9

    override var acceptsFirstResponder: Bool { true }

    func select(_ a: PDFAnnotation?, on page: PDFPage?) {
        let old = selectedPage
        selectedObject = a
        selectedPage = page
        if let old { annotationsChanged(on: old) }
        if let page { annotationsChanged(on: page) }
    }

    private func object(at viewPoint: CGPoint) -> (PDFAnnotation, PDFPage, CGPoint)? {
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let p = convert(viewPoint, to: page)
        let hit = page.annotations.reversed().first {
            Objects.objectID($0) != nil && $0.bounds.insetBy(dx: -Self.handle, dy: -Self.handle).contains(p)
        }
        return hit.map { ($0, page, p) }
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if let (a, page, p) = object(at: v) {
            window?.makeFirstResponder(self)
            select(a, on: page)
            if event.clickCount == 2 { onEdit?(a, page); return }
            dragStart = p
            startBounds = a.bounds
            resizing = abs(p.x - a.bounds.maxX) <= Self.handle && abs(p.y - a.bounds.minY) <= Self.handle
            moved = false
            return
        }
        if selectedObject != nil { select(nil, on: nil) }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let a = selectedObject, let page = selectedPage, let start = dragStart, let b = startBounds else {
            super.mouseDragged(with: event); return
        }
        let p = convert(convert(event.locationInWindow, from: nil), to: page)
        let dx = p.x - start.x, dy = p.y - start.y
        if resizing {
            // Bottom-right handle in PDF space: right edge follows x, bottom edge follows y.
            var w = max(16, b.width + dx)
            var h = max(10, b.height - dy)
            if let img = a as? ImageStampAnnotation {        // images keep their proportions
                let aspect = CGFloat(img.image.height) / CGFloat(max(1, img.image.width))
                h = w * aspect
                if h < 10 { h = 10; w = h / aspect }
            }
            a.bounds = CGRect(x: b.minX, y: b.maxY - h, width: w, height: h)
        } else {
            a.bounds = b.offsetBy(dx: dx, dy: dy)
        }
        moved = true
        annotationsChanged(on: page)
    }

    override func mouseUp(with event: NSEvent) {
        if let a = selectedObject, let page = selectedPage, moved { onCommit?(a, page) }
        dragStart = nil; startBounds = nil; moved = false; resizing = false
        if selectedObject == nil { super.mouseUp(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        guard let a = selectedObject, let page = selectedPage else { super.keyDown(with: event); return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: onDelete?(a, page); select(nil, on: nil)                 // delete, forward delete
        case 53: select(nil, on: nil)                                           // escape
        case 123: a.bounds.origin.x -= step; annotationsChanged(on: page); onCommit?(a, page)
        case 124: a.bounds.origin.x += step; annotationsChanged(on: page); onCommit?(a, page)
        case 125: a.bounds.origin.y -= step; annotationsChanged(on: page); onCommit?(a, page)
        case 126: a.bounds.origin.y += step; annotationsChanged(on: page); onCommit?(a, page)
        case 36: onEdit?(a, page)                                               // return
        default: super.keyDown(with: event)
        }
    }

    /// Selection outline and resize handle, drawn in page space after the page.
    override func draw(_ page: PDFPage, to context: CGContext) {
        super.draw(page, to: context)
        guard let a = selectedObject, page == selectedPage else { return }
        let r = a.bounds.insetBy(dx: -3, dy: -3)
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.2)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(r)
        context.setLineDash(phase: 0, lengths: [])
        context.setFillColor(NSColor.white.cgColor)
        let h = CGRect(x: r.maxX - 4, y: r.minY - 4, width: 8, height: 8)
        context.fillEllipse(in: h)
        context.strokeEllipse(in: h)
        context.restoreGState()
    }
}
