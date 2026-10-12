import AppKit
// Convert the approved generated artwork into every macOS icon size, preserving alpha.
// Usage: swift MakeIcon.swift Omega-Icon.png path/to/Omega.iconset
let source = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
guard let image = NSImage(contentsOfFile: source) else { fatalError("Missing icon artwork") }
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
let sizes = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (size, scale) in sizes {
    let pixels = size * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep); NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
