import Foundation
import Network
import Darwin

/// Blocks fetches of local-network addresses. ezpdf can be driven by remote bots, so a
/// "convert this link" request must never read your router page or a local service and
/// hand it back to the bot. Applied to the first URL, every redirect, and (through a WebKit
/// content rule list) every resource a rendered page loads. Names are resolved and checked too;
/// a name that changes its answer between the check and the fetch (DNS rebinding) isn't covered.
public enum URLGuard {
    public static func isAllowed(_ url: URL, allowLocal: Bool = false) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if allowLocal { return true }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }

        let blockedSuffixes = [".localhost", ".local", ".internal", ".home.arpa", ".lan"]
        if host == "localhost" || blockedSuffixes.contains(where: host.hasSuffix) { return false }
        // Numeric host spellings ("2130706433", "0x7f.1", "0177.0.0.1") resolve differently in
        // different parsers. Only a plain dotted quad with no leading zeros is accepted.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.hasPrefix("0x") || host.contains(".0x") {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            let plainQuad = parts.count == 4 && parts.allSatisfy { p in
                !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) && (p == "0" || !p.hasPrefix("0")) && (Int(p) ?? 999) <= 255
            }
            guard plainQuad, let v4 = IPv4Address(host) else { return false }
            return isPublic(v4)
        }

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
        if b[0..<12].allSatisfy({ $0 == 0 }) { return false }                // ::a.b.c.d (IPv4-compatible)
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b { return false } // 64:ff9b::/96 NAT64
        if b[0] == 0x20, b[1] == 0x02 { return false }                       // 2002::/16 6to4
        // IPv4-mapped ::ffff:a.b.c.d
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff,
           let v4 = IPv4Address(Data(b[12..<16])) {
            return isPublic(v4)
        }
        return true
    }

    // MARK: DNS

    /// Resolves `host` and returns true only if every address it resolves to is public. Catches
    /// names like `localtest.me` or `192-168-1-1.nip.io` that point at private addresses.
    /// (A name can still change answers between this check and the real fetch: DNS rebinding.)
    public static func resolvesPublic(_ url: URL, allowLocal: Bool = false) async -> Bool {
        guard isAllowed(url, allowLocal: allowLocal) else { return false }
        if allowLocal { return true }
        guard let host = url.host(percentEncoded: false)?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return true }   // literal: already checked
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { c.resume(returning: false); return }
                defer { freeaddrinfo(first) }
                var ok = true, any = false
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let ai = p {
                    if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                        let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                        let bytes = withUnsafeBytes(of: addr.s_addr) { Data($0) }
                        if let v4 = IPv4Address(bytes) { any = true; ok = ok && isPublic(v4) }
                    } else if ai.pointee.ai_family == AF_INET6, let sa = ai.pointee.ai_addr {
                        let addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                        let bytes = withUnsafeBytes(of: addr) { Data($0) }
                        if let v6 = IPv6Address(bytes) { any = true; ok = ok && isPublic(v6) }
                    }
                    p = ai.pointee.ai_next
                }
                c.resume(returning: ok && any)
            }
        }
    }

    // MARK: WebKit

    /// Blocks every load (images, scripts, fetch, CSS, frames, websockets) to literal private
    /// addresses and local names inside pages ezpdf renders. Navigations are also checked by
    /// WebSession; names that resolve privately are checked before the page is opened.
    static let contentRules: String = {
        // WebKit url-filter regexes (single backslashes here; JSONSerialization escapes them).
        let hosts = [
            #"127\."#, #"10\."#, #"0\."#, #"169\.254\."#, #"192\.168\."#,
            #"172\.1[6-9]\."#, #"172\.2[0-9]\."#, #"172\.3[01]\."#,
            #"100\.6[4-9]\."#, #"100\.[7-9][0-9]\."#, #"100\.1[01][0-9]\."#, #"100\.12[0-7]\."#,
            #"\["#, #"localhost[:/]"#, #"localhost$"#, #"[^/]*\.localhost[:/]"#, #"[^/]*\.local[:/]"#, #"[^/]*\.local$"#,
            #"[^/]*\.internal[:/]"#, #"[^/]*\.home\.arpa[:/]"#, #"[^/]*\.lan[:/]"#, #"[0-9]+[:/]"#, #"0x"#,
        ]
        var rules: [[String: Any]] = []
        for h in hosts {
            for scheme in ["https?", "wss?"] {
                rules.append(["trigger": ["url-filter": "^\(scheme)://\(h)"], "action": ["type": "block"]])
                rules.append(["trigger": ["url-filter": "^\(scheme)://[^/@]*@\(h)"], "action": ["type": "block"]])
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }()
}
