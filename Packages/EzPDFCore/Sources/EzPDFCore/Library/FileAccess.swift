import Foundation

/// Path rules for anything a caller (agent, extension) names on disk. Paths are compared after
/// resolving symlinks and `..`, by whole path components, never by string prefix.
public enum FileAccess {
    /// Folders local agents may read files from.
    static var agentReadableRoots: [URL] {
        let fm = FileManager.default
        return [.downloadsDirectory, .desktopDirectory, .documentDirectory].compactMap {
            fm.urls(for: $0, in: .userDomainMask).first
        }
    }

    static let maxAgentFileBytes = 200 * 1024 * 1024

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// True when `url` is `root` or inside it.
    public static func isInside(_ url: URL, _ root: URL) -> Bool {
        let a = canonical(url).pathComponents, b = canonical(root).pathComponents
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }

    /// A file an agent asked to convert: inside Downloads/Desktop/Documents, not hidden, a regular
    /// file of a supported type and a sane size. Errors don't reveal whether other paths exist.
    static func checkedAgentPath(_ raw: String) throws -> URL {
        let refused = EzPDFError.invalidInput("ezpdf can only open files in your Downloads, Desktop or Documents folders that it can convert.")
        let url = canonical(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        guard agentReadableRoots.contains(where: { isInside(url, $0) }) else { throw refused }
        guard !url.pathComponents.contains(where: { $0.hasPrefix(".") }) else { throw refused }
        guard FileConverter.supportedExtensions.contains(url.pathExtension.lowercased()) else { throw refused }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size <= maxAgentFileBytes else { throw refused }
        return url
    }

    /// One folder name inside the export folder (no slashes, no `..`, not hidden).
    static func exportSubfolder(_ name: String, in root: URL) throws -> URL {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count <= 80, !n.contains("/"), !n.contains(":"), !n.hasPrefix("."), n != ".." else {
            throw EzPDFError.invalidInput("Use a plain folder name for subfolder.")
        }
        return root.appendingPathComponent(n, isDirectory: true)
    }
}
