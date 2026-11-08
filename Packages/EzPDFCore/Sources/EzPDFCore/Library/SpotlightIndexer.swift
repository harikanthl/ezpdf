import Foundation
import CoreSpotlight
import PDFKit
import UniformTypeIdentifiers

/// Puts every library document in Spotlight (title, source and full text), so ⌘Space finds
/// what's inside your PDFs. Selecting a result opens it in ezpdf (activity identifier = doc id).
public enum SpotlightIndexer {
    static let domain = "ai.harikanth.ezpdf.documents"
    static let queue = DispatchQueue(label: "ezpdf.spotlight", qos: .utility)

    static var enabled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func index(_ rec: DocumentRecord, pdf: URL) {
        guard enabled else { return }
        queue.async {
            let attrs = CSSearchableItemAttributeSet(contentType: .pdf)
            attrs.title = rec.title
            attrs.displayName = rec.title
            attrs.contentDescription = [rec.siteName, rec.byline, rec.excerpt].compactMap { $0 }.joined(separator: " · ")
            attrs.contentURL = pdf
            attrs.pageCount = NSNumber(value: rec.pageCount)
            if let s = rec.sourceURL { attrs.url = URL(string: s) }
            if let doc = PDFDocument(url: pdf) {
                var text = ""
                for i in 0..<min(doc.pageCount, 300) {
                    text += (doc.page(at: i)?.string ?? "") + "\n"
                    if text.count > 200_000 { break }
                }
                attrs.textContent = text
            }
            let item = CSSearchableItem(uniqueIdentifier: rec.id, domainIdentifier: domain, attributeSet: attrs)
            CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
        }
    }

    static func remove(_ id: String) {
        guard enabled else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id]) { _ in }
    }
}
