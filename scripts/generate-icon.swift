import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output-icns-path>\n", stderr)
    exit(1)
}

let outPath = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outPath.deletingLastPathComponent(), withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data {
    let s = CGFloat(pixelSize)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Squircle-style rounded rect background
    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = s * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    cg.addPath(path)
    cg.clip()

    let colors = [
        NSColor(calibratedRed: 0.09, green: 0.14, blue: 0.14, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.12, green: 0.21, blue: 0.21, alpha: 1.0).cgColor,
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Subtle border
    cg.resetClip()
    cg.addPath(path)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    cg.setLineWidth(max(1.0, s * 0.015))
    cg.strokePath()

    // 4x4 Heatmap matrix
    let matrixLevels: [[Int]] = [
        [1, 3, 2, 0],
        [2, 4, 3, 1],
        [0, 2, 4, 3],
        [1, 1, 3, 4],
    ]
    let palette: [NSColor] = [
        NSColor(calibratedRed: 0.137, green: 0.173, blue: 0.173, alpha: 1.0), // #232C2C
        NSColor(calibratedRed: 0.075, green: 0.306, blue: 0.290, alpha: 1.0), // #134E4A
        NSColor(calibratedRed: 0.059, green: 0.463, blue: 0.431, alpha: 1.0), // #0F766E
        NSColor(calibratedRed: 0.078, green: 0.722, blue: 0.651, alpha: 1.0), // #14B8A6
        NSColor(calibratedRed: 0.369, green: 0.918, blue: 0.831, alpha: 1.0), // #5EEAD4
    ]

    let pad = s * 0.22
    let gap = s * 0.045
    let avail = s - pad * 2 - gap * 3
    let cell = avail / 4.0
    let cellCorner = max(1.0, cell * 0.24)

    for r in 0..<4 {
        for c in 0..<4 {
            let lv = matrixLevels[3 - r][c]
            let x = pad + CGFloat(c) * (cell + gap)
            let y = pad + CGFloat(r) * (cell + gap)
            let cellRect = CGRect(x: x, y: y, width: cell, height: cell)
            let cp = CGPath(roundedRect: cellRect, cornerWidth: cellCorner, cornerHeight: cellCorner, transform: nil)
            cg.addPath(cp)
            cg.setFillColor(palette[lv].cgColor)
            cg.fillPath()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let icnsChunks: [(String, Int)] = [
    ("icp4", 16),
    ("ic11", 32),
    ("icp5", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024),
]

var bodyData = Data()
for (chunkType, px) in icnsChunks {
    let png = renderIcon(pixelSize: px)
    let typeBytes = Array(chunkType.utf8)
    if typeBytes.count != 4 { continue }
    bodyData.append(contentsOf: typeBytes)
    var chunkLen = UInt32(8 + png.count).bigEndian
    withUnsafeBytes(of: &chunkLen) { bodyData.append(contentsOf: $0) }
    bodyData.append(png)
}

var icnsData = Data("icns".utf8)
var totalLen = UInt32(8 + bodyData.count).bigEndian
withUnsafeBytes(of: &totalLen) { icnsData.append(contentsOf: $0) }
icnsData.append(bodyData)

try icnsData.write(to: outPath)
