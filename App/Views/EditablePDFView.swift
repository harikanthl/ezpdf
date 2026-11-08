import AppKit
import PDFKit
import EzPDFCore

/// PDFView that lets you work with placed objects (text boxes, signatures, images, boxes):
/// click selects, drag moves, the corner handle resizes, arrow keys nudge, Delete removes,
/// double-click edits. Everything else (text selection, links, forms) behaves as usual.
///
/// All the geometry is done in the page's shown space (crop box after rotation), so on a rotated
/// page the handle is the corner you see, and arrows move the way they point.
final class EditablePDFView: PDFView, NSMenuItemValidation {
    private(set) var selectedObject: PDFAnnotation?
    private(set) weak var selectedPage: PDFPage?
    var onCommit: ((PDFAnnotation, PDFPage) -> Void)?
    var onDelete: ((PDFAnnotation, PDFPage) -> Void)?
    var onEdit: ((PDFAnnotation, PDFPage) -> Void)?
    /// Copy (and Cut) of a selected object; Paste of an object, a picture or text from the clipboard.
    var onCopyObject: ((PDFAnnotation, PDFPage) -> Void)?
    var onPaste: (() -> Void)?
    var canPaste: () -> Bool = { false }

    /// Drag state, in the selected page's shown space (bottom-left origin).
    private var dragStart: CGPoint?
    private var startShown: CGRect?
    private var resizing = false
    private var moved = false
    private static let handle: CGFloat = 9
    /// Arrow-key nudges are saved once, shortly after the last key, not on every press.
    private var nudgeCommit: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }

    func select(_ a: PDFAnnotation?, on page: PDFPage?) {
        if a !== selectedObject { flushNudge() }
        let old = selectedPage
        selectedObject = a
        selectedPage = page
        if let old { annotationsChanged(on: old) }
        if let page { annotationsChanged(on: page) }
    }

    /// Saves a pending nudge now (before anything else happens to the object or the document).
    func flushNudge() {
        guard let work = nudgeCommit else { return }
        nudgeCommit = nil
        work.cancel()
        work.perform()
    }

    private func shownPoint(_ viewPoint: CGPoint, on page: PDFPage) -> CGPoint {
        convert(viewPoint, to: page).applying(EditOps.PageSpace(page).toShown)
    }

    private func object(at viewPoint: CGPoint) -> (PDFAnnotation, PDFPage)? {
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let p = convert(viewPoint, to: page)
        let hit = page.annotations.reversed().first {
            Objects.objectID($0) != nil && $0.bounds.insetBy(dx: -Self.handle, dy: -Self.handle).contains(p)
        }
        return hit.map { ($0, page) }
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if let (a, page) = object(at: v) {
            window?.makeFirstResponder(self)
            select(a, on: page)
            if event.clickCount == 2 { onEdit?(a, page); return }
            let space = EditOps.PageSpace(page)
            let p = shownPoint(v, on: page)
            let shown = a.bounds.applying(space.toShown)
            dragStart = p
            startShown = shown
            // The handle is the bottom-right corner as shown (bottom-left origin: maxX, minY).
            resizing = abs(p.x - shown.maxX) <= Self.handle && abs(p.y - shown.minY) <= Self.handle
            moved = false
            return
        }
        if selectedObject != nil { select(nil, on: nil) }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let a = selectedObject, let page = selectedPage, let start = dragStart, let b = startShown else {
            super.mouseDragged(with: event); return
        }
        let space = EditOps.PageSpace(page)
        let p = shownPoint(convert(event.locationInWindow, from: nil), on: page)
        let dx = p.x - start.x, dy = p.y - start.y
        var r: CGRect
        if resizing {
            // Right edge follows x, bottom edge follows y; the top-left corner stays put.
            var w = max(16, b.width + dx)
            var h = max(10, b.height - dy)
            if let img = a as? ImageStampAnnotation, img.image.width > 0, img.image.height > 0 {
                // Images keep their proportions as shown (the image is drawn upright).
                let aspect = CGFloat(img.image.height) / CGFloat(img.image.width)
                h = w * aspect
                if h < 10 { h = 10; w = h / aspect }
            }
            r = CGRect(x: b.minX, y: b.maxY - h, width: w, height: h)
        } else {
            r = b.offsetBy(dx: dx, dy: dy)
        }
        // Keep it reachable: at least a corner stays on the page.
        let area = CGRect(origin: .zero, size: space.size)
        r.origin.x = min(max(r.minX, area.minX - r.width + 12), area.maxX - 12)
        r.origin.y = min(max(r.minY, area.minY - r.height + 12), area.maxY - 12)
        a.bounds = r.applying(space.toPage)
        moved = true
        annotationsChanged(on: page)
    }

    override func mouseUp(with event: NSEvent) {
        if let a = selectedObject, let page = selectedPage, moved { onCommit?(a, page) }
        let hadObjectDrag = dragStart != nil
        dragStart = nil; startShown = nil; moved = false; resizing = false
        if !hadObjectDrag { super.mouseUp(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        guard let a = selectedObject, let page = selectedPage else { super.keyDown(with: event); return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117:                                                            // delete, forward delete
            nudgeCommit?.cancel(); nudgeCommit = nil
            onDelete?(a, page); select(nil, on: nil)
        case 53: select(nil, on: nil)                                            // escape
        case 123: nudge(a, on: page, dx: -step, dy: 0)
        case 124: nudge(a, on: page, dx: step, dy: 0)
        case 125: nudge(a, on: page, dx: 0, dy: -step)                           // down, as shown
        case 126: nudge(a, on: page, dx: 0, dy: step)
        case 36: flushNudge(); onEdit?(a, page)                                  // return
        default: super.keyDown(with: event)
        }
    }

    private func nudge(_ a: PDFAnnotation, on page: PDFPage, dx: CGFloat, dy: CGFloat) {
        let space = EditOps.PageSpace(page)
        a.bounds = a.bounds.applying(space.toShown).offsetBy(dx: dx, dy: dy).applying(space.toPage)
        annotationsChanged(on: page)
        nudgeCommit?.cancel()
        let work = DispatchWorkItem { [weak self, weak a, weak page] in
            guard let self, let a, let page else { return }
            self.nudgeCommit = nil
            self.onCommit?(a, page)
        }
        nudgeCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Copy and paste

    /// With an object selected, Copy copies the object; otherwise the selected text, as usual.
    override func copy(_ sender: Any?) {
        guard let a = selectedObject, let page = selectedPage else { super.copy(sender); return }
        onCopyObject?(a, page)
    }

    @objc func cut(_ sender: Any?) {
        guard let a = selectedObject, let page = selectedPage else { NSSound.beep(); return }
        onCopyObject?(a, page)
        nudgeCommit?.cancel(); nudgeCommit = nil
        onDelete?(a, page)
        select(nil, on: nil)
    }

    @objc func paste(_ sender: Any?) {
        guard canPaste() else { NSSound.beep(); return }
        flushNudge()
        onPaste?()
    }

    /// Cut, Copy and Paste are on only when they'd do something; other actions stay as PDFView has them
    /// (on when the view can perform them, as AppKit does by default).
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(cut(_:)): return selectedObject != nil
        case #selector(paste(_:)): return canPaste()
        case #selector(copy(_:)): return selectedObject != nil || !(currentSelection?.string ?? "").isEmpty
        default: return item.action.map { responds(to: $0) } ?? false
        }
    }

    /// Selection outline and resize handle (at the shown bottom-right corner), drawn after the page.
    override func draw(_ page: PDFPage, to context: CGContext) {
        super.draw(page, to: context)
        guard let a = selectedObject, page == selectedPage else { return }
        let space = EditOps.PageSpace(page)
        let r = a.bounds.applying(space.toShown).insetBy(dx: -3, dy: -3)
        context.saveGState()
        context.concatenate(space.toPage)          // draw in shown space
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
