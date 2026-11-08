import Foundation
import CoreGraphics

/// Page geometry and type scale for a target device. Points == CSS px in the layout web view,
/// so `fontSize` is both the CSS size and the printed size before the reader scales the page.
public enum PagePreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case kindle          // Paperwhite / Basic / Colorsoft (3:4 screen)
    case kindleScribe    // 10.2" Scribe (3:4, larger)
    case phone
    case letter
    case a4
    case web             // the page as it looks in a browser, no reader cleanup

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kindle: return "Kindle"
        case .kindleScribe: return "Kindle Scribe"
        case .phone: return "Phone"
        case .letter: return "Letter"
        case .a4: return "A4"
        case .web: return "As on the web"
        }
    }

    public var detail: String {
        switch self {
        case .kindle: return "Large type, 3:4 pages for 6–7″ e-readers"
        case .kindleScribe: return "3:4 pages sized for the 10″ Scribe"
        case .phone: return "Tall pages for reading on a phone"
        case .letter: return "8.5 × 11 in, for printing"
        case .a4: return "210 × 297 mm, for printing"
        case .web: return "Keeps the site's own design"
        }
    }

    public var pageSize: CGSize {
        switch self {
        case .kindle: return CGSize(width: 432, height: 576)
        case .kindleScribe: return CGSize(width: 540, height: 720)
        case .phone: return CGSize(width: 360, height: 680)
        case .letter: return CGSize(width: 612, height: 792)
        case .a4: return CGSize(width: 595, height: 842)
        case .web: return CGSize(width: 1000, height: 1414)
        }
    }

    public var margin: CGFloat {
        switch self {
        case .kindle: return 22
        case .kindleScribe: return 30
        case .phone: return 18
        case .letter, .a4: return 54
        case .web: return 0
        }
    }

    public var fontSize: CGFloat {
        switch self {
        case .kindle: return 17
        case .kindleScribe: return 15
        case .phone: return 16
        case .letter, .a4: return 12.5
        case .web: return 16
        }
    }

    public var contentSize: CGSize {
        CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
    }

    /// Lenient parse for agents and URLs ("Kindle Scribe", "kindle-scribe", "scribe").
    public static func parse(_ s: String?) -> PagePreset? {
        guard let s = s?.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression),
              !s.isEmpty else { return nil }
        if let p = PagePreset(rawValue: s) { return p }
        switch s {
        case "kindlescribe", "scribe": return .kindleScribe
        case "paperwhite", "ereader", "kindlepaperwhite": return .kindle
        case "original", "asis", "asontheweb", "screenshot", "visual": return .web
        case "usletter": return .letter
        case "mobile", "iphone": return .phone
        default: return nil
        }
    }
}

public enum OutputFormat: String, Codable, Sendable, CaseIterable {
    case pdf, epub, both

    public static func parse(_ s: String?) -> OutputFormat? {
        guard let s = s?.lowercased() else { return nil }
        return OutputFormat(rawValue: s)
    }
}
