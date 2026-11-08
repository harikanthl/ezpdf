import Foundation
import Compression

/// Minimal ZIP writer (stored + deflate) for EPUB and XLSX. Apple's COMPRESSION_ZLIB emits raw
/// DEFLATE, which is exactly ZIP method 8.
public struct ZipWriter {
    private struct Entry { let name: Data; let crc: UInt32; let method: UInt16; let compSize: UInt32; let size: UInt32; let offset: UInt32 }

    private var out = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    public init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let t: Int = (hour << 11) | (minute << 5) | (second / 2)
        let d: Int = (year << 9) | (month << 5) | day
        dosTime = UInt16(truncatingIfNeeded: t)
        dosDate = UInt16(truncatingIfNeeded: d)
    }

    public mutating func add(_ path: String, _ data: Data, compress: Bool = true) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var body = data
        if compress, data.count > 64, let d = Self.deflate(data), d.count < data.count {
            method = 8; body = d
        }
        let offset = UInt32(out.count)
        out.append(le32(0x04034b50))
        out.append(le16(20)); out.append(le16(0x0800))    // version, flags (UTF-8 names)
        out.append(le16(method)); out.append(le16(dosTime)); out.append(le16(dosDate))
        out.append(le32(crc)); out.append(le32(UInt32(body.count))); out.append(le32(UInt32(data.count)))
        out.append(le16(UInt16(name.count))); out.append(le16(0))
        out.append(name); out.append(body)
        entries.append(Entry(name: name, crc: crc, method: method, compSize: UInt32(body.count), size: UInt32(data.count), offset: offset))
    }

    public mutating func add(_ path: String, _ text: String, compress: Bool = true) {
        add(path, Data(text.utf8), compress: compress)
    }

    public func finish() -> Data {
        var data = out
        let cdStart = UInt32(data.count)
        for e in entries {
            data.append(le32(0x02014b50))
            data.append(le16(20)); data.append(le16(20)); data.append(le16(0x0800))
            data.append(le16(e.method)); data.append(le16(dosTime)); data.append(le16(dosDate))
            data.append(le32(e.crc)); data.append(le32(e.compSize)); data.append(le32(e.size))
            data.append(le16(UInt16(e.name.count))); data.append(le16(0)); data.append(le16(0))
            data.append(le16(0)); data.append(le16(0)); data.append(le32(0)); data.append(le32(e.offset))
            data.append(e.name)
        }
        let cdSize = UInt32(data.count) - cdStart
        data.append(le32(0x06054b50)); data.append(le16(0)); data.append(le16(0))
        data.append(le16(UInt16(entries.count))); data.append(le16(UInt16(entries.count)))
        data.append(le32(cdSize)); data.append(le32(cdStart)); data.append(le16(0))
        return data
    }

    static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 10 + 1024
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          s.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFFFFFF
    }
}
