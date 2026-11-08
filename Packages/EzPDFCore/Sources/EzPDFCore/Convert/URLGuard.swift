import Foundation
import Network

/// Blocks fetches of local-network addresses. ezpdf can be driven by remote bots, so a
/// "convert this link" request must never read your router page or a local service and
/// hand it back to the bot. Applied to the first URL and to every main-frame redirect.
/// (DNS rebinding — a public name resolving to a private address — is not covered.)
public enum URLGuard {
    public static func isAllowed(_ url: URL, allowLocal: Bool = false) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if allowLocal { return true }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }

        let blockedSuffixes = [".localhost", ".local", ".internal", ".home.arpa", ".lan"]
        if host == "localhost" || blockedSuffixes.contains(where: host.hasSuffix) { return false }
        // Integer / hex host forms ("2130706433", "0x7f000001") resolve to IPs; refuse them.
        if host.allSatisfy({ $0.isNumber }) || host.hasPrefix("0x") { return false }

        if let v4 = IPv4Address(host) { return isPublic(v4) }
        if let v6 = IPv6Address(host) { return isPublic(v6) }
        return true
    }

    static func isPublic(_ ip: IPv4Address) -> Bool {
        let b = [UInt8](ip.rawValue)
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): return false
        case (169, 254): return false
        case (172, 16...31): return false
        case (192, 168): return false
        case (100, 64...127): return false        // carrier-grade NAT
        case (198, 18...19): return false         // benchmarking
        case (224...255, _): return false         // multicast, reserved, broadcast
        default: return true
        }
    }

    static func isPublic(_ ip: IPv6Address) -> Bool {
        let b = [UInt8](ip.rawValue)
        guard b.count == 16 else { return false }
        if b.allSatisfy({ $0 == 0 }) { return false }                         // ::
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return false }  // ::1
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return false }            // fe80::/10
        if (b[0] & 0xfe) == 0xfc { return false }                            // fc00::/7
        if b[0] == 0xff { return false }                                     // multicast
        // IPv4-mapped ::ffff:a.b.c.d
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff,
           let v4 = IPv4Address(Data(b[12..<16])) {
            return isPublic(v4)
        }
        return true
    }
}
