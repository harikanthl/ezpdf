import AppKit
let src = NSImage(contentsOfFile: CommandLine.arguments[1])!
let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)!
// Find the mark's bounding box: pixels clearly darker/more saturated than the off-white background.
let w = cg.width, h = cg.height
let ctx0 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx0.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx0.data!.assumingMemoryBound(to: UInt8.self)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h { for x in 0..<w {
    let i = (y * w + x) * 4
    let r = Int(px[i]), g = Int(px[i+1]), b = Int(px[i+2])
    if max(r, g, b) - min(r, g, b) > 40 || (r + g + b) < 600 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
}}
let bg = NSColor(red: CGFloat(px[(8 * w + 8) * 4]) / 255, green: CGFloat(px[(8 * w + 8) * 4 + 1]) / 255, blue: CGFloat(px[(8 * w + 8) * 4 + 2]) / 255, alpha: 1)
let crop = cg.cropping(to: CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1))!
print("mark bbox", minX, minY, maxX, maxY)

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.setFillColor(bg.cgColor); ctx.fill(body)
    // Mark fills ~70% of the tile width (more at tiny sizes for legibility).
    let fill: CGFloat = size <= 32 ? 0.84 : 0.70
    let mw = body.width * fill, mh = mw * CGFloat(crop.height) / CGFloat(crop.width)
    ctx.draw(crop, in: CGRect(x: body.midX - mw / 2, y: body.midY - mh / 2, width: mw, height: mh))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let out = CommandLine.arguments[2]
for (size, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales { try! draw(size * sc).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)\(sc == 2 ? "@2x" : "").png")) }
}
let ext = CommandLine.arguments[3]
for size in [16, 32, 48, 128] { try! draw(size).write(to: URL(fileURLWithPath: "\(ext)/icon-\(size).png")) }
try! draw(1024).write(to: URL(fileURLWithPath: "design/app-icon-1024.png"))
