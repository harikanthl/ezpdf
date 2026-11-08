import AppKit
import UniformTypeIdentifiers

/// Placed objects on the clipboard. A copied object goes up in ezpdf's own form (so a paste brings
/// back the same font, size, color or image) and also as plain text or a PNG for other apps.
enum ObjectClipboard {
    static let type = NSPasteboard.PasteboardType("ai.harikanth.ezpdf.object")

    struct Clip: Codable {
        var documentID: String
        var page: Int               // 0-based
        var rect: CGRect            // top-left points of the page as shown
        var text: String?
        var fontName: String?
        var fontSize: Double?
        var color: String?          // #RRGGBB
        var image: Data?            // PNG
        var shape: String?
    }

    static func write(_ clip: Clip, to pb: NSPasteboard) {
        guard let data = try? JSONEncoder().encode(clip) else { return }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        if let text = clip.text { item.setString(text, forType: .string) }
        if let png = clip.image { item.setData(png, forType: .png) }
        pb.writeObjects([item])
    }

    static func read(_ pb: NSPasteboard) -> Clip? {
        pb.data(forType: type).flatMap { try? JSONDecoder().decode(Clip.self, from: $0) }
    }

    /// A picture from another app (a screenshot, an image copied in Preview or a browser).
    static func image(_ pb: NSPasteboard) -> Data? {
        for t in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                  NSPasteboard.PasteboardType(UTType.heic.identifier)] {
            if let d = pb.data(forType: t) { return d }
        }
        // A copied image file (Finder).
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
           UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    static func hasContent(_ pb: NSPasteboard) -> Bool {
        pb.availableType(from: [type, .png, .tiff, .string, .fileURL]) != nil
    }
}
