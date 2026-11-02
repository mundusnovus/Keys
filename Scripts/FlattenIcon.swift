import AppKit
import CoreGraphics
import Foundation
import ImageIO

// App Store rejects the 1024 marketing icon when the PNG has an alpha channel.
// This keeps the rendered Keys artwork and composites any transparency onto a solid backdrop.

struct RGB {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var hex: String {
        String(format: "%02X%02X%02X", r, g, b)
    }
}

enum Fail: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

func parseHex(_ text: String) -> RGB {
    var hex = text
    if hex.hasPrefix("#") {
        hex.removeFirst()
    }
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
        fputs("error: bad color \(text)\n", stderr)
        exit(1)
    }
    return RGB(
        r: UInt8((value >> 16) & 0xff),
        g: UInt8((value >> 8) & 0xff),
        b: UInt8(value & 0xff)
    )
}

func loadImage(_ path: String) throws -> CGImage {
    guard let image = loadImageOptional(path) else {
        throw Fail.message("cannot read \(path)")
    }
    return image
}

func loadImageOptional(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func draw(_ image: CGImage, width: Int, height: Int, fallback: RGB) throws -> (rgb: [UInt8], backdrop: RGB, opaquePercent: Int) {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info
        ) else {
            return false
        }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    if !drew {
        throw Fail.message("could not draw icon")
    }

    // A source PNG with no alpha plane can draw RGB while leaving the alpha byte at 0.
    var maxAlpha = 0
    var scan = 0
    while scan < pixels.count {
        let alpha = Int(pixels[scan + 3])
        if alpha > maxAlpha { maxAlpha = alpha }
        scan += 4
    }
    if maxAlpha == 0 {
        scan = 0
        while scan < pixels.count {
            pixels[scan + 3] = 255
            scan += 4
        }
    }

    var counts = [Int](repeating: 0, count: 4096)
    var sumR = [Int](repeating: 0, count: 4096)
    var sumG = [Int](repeating: 0, count: 4096)
    var sumB = [Int](repeating: 0, count: 4096)
    var opaque = 0
    var index = 0
    while index < pixels.count {
        let alpha = Int(pixels[index + 3])
        if alpha == 255 {
            opaque += 1
            let r = Int(pixels[index])
            let g = Int(pixels[index + 1])
            let b = Int(pixels[index + 2])
            let bucket = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            counts[bucket] += 1
            sumR[bucket] += r
            sumG[bucket] += g
            sumB[bucket] += b
        }
        index += 4
    }

    let total = width * height
    let backdrop: RGB
    if opaque * 20 >= total, let bucket = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[bucket] > 0 {
        let count = counts[bucket]
        backdrop = RGB(
            r: UInt8(sumR[bucket] / count),
            g: UInt8(sumG[bucket] / count),
            b: UInt8(sumB[bucket] / count)
        )
    } else {
        backdrop = fallback
    }

    var rgb = [UInt8](repeating: 0, count: total * 3)
    let backgroundR = Int(backdrop.r)
    let backgroundG = Int(backdrop.g)
    let backgroundB = Int(backdrop.b)
    index = 0
    var out = 0
    while index < pixels.count {
        let alpha = Int(pixels[index + 3])
        let inverse = 255 - alpha
        rgb[out] = mix(pixels[index], backgroundR, inverse)
        rgb[out + 1] = mix(pixels[index + 1], backgroundG, inverse)
        rgb[out + 2] = mix(pixels[index + 2], backgroundB, inverse)
        index += 4
        out += 3
    }
    let percent = total == 0 ? 0 : opaque * 100 / total
    return (rgb, backdrop, percent)
}

func mix(_ source: UInt8, _ background: Int, _ inverseAlpha: Int) -> UInt8 {
    let value = Int(source) + (background * inverseAlpha + 127) / 255
    if value <= 0 { return 0 }
    if value >= 255 { return 255 }
    return UInt8(value)
}

func pngData(width: Int, height: Int, rgb: [UInt8]) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 3,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let dest = rep.bitmapData else {
        throw Fail.message("could not allocate an opaque bitmap")
    }
    if rep.samplesPerPixel != 3 || rep.hasAlpha {
        throw Fail.message("bitmap still has an alpha channel")
    }
    let rowBytes = rep.bytesPerRow
    for y in 0..<height {
        for x in 0..<width {
            let source = (y * width + x) * 3
            let offset = y * rowBytes + x * 3
            dest[offset] = rgb[source]
            dest[offset + 1] = rgb[source + 1]
            dest[offset + 2] = rgb[source + 2]
        }
    }
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw Fail.message("could not encode png")
    }
    if data.count > 25, data[25] != 2 {
        throw Fail.message("png color type \(data[25]) still allows transparency")
    }
    return data
}

func assertSamePicture(_ before: [UInt8], _ after: [UInt8], width: Int, height: Int) throws {
    let points = [
        (width / 2, height / 2),
        (0, 0),
        (width - 1, 0),
        (0, height - 1),
        (width / 2, height / 5),
    ]
    for (x, y) in points {
        let index = (y * width + x) * 3
        for channel in 0..<3 {
            let delta = abs(Int(before[index + channel]) - Int(after[index + channel]))
            if delta > 12 {
                throw Fail.message("rewritten icon changed pixel \(x),\(y) from \(before[index]),\(before[index + 1]),\(before[index + 2]) to \(after[index]),\(after[index + 1]),\(after[index + 2])")
            }
        }
    }
}

func writeAtomically(_ data: Data, to path: String) throws {
    let output = URL(fileURLWithPath: path)
    let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).flattening")
    try data.write(to: temporary, options: .atomic)
    if FileManager.default.fileExists(atPath: path) {
        _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
    } else {
        try FileManager.default.moveItem(at: temporary, to: output)
    }
}

let arguments = CommandLine.arguments
if arguments.count < 4 {
    fputs("usage: flatten-icon [--resize] input output-or-size output [RRGGBB]\n", stderr)
    exit(1)
}

let resizing = arguments[1] == "--resize"
let inputPath: String
let outputPath: String
let edge: Int?
let fallback: RGB

if resizing {
    guard arguments.count == 6, let pixels = Int(arguments[3]), pixels > 0 else {
        fputs("usage: flatten-icon --resize input pixels output RRGGBB\n", stderr)
        exit(1)
    }
    inputPath = arguments[2]
    edge = pixels
    outputPath = arguments[4]
    fallback = parseHex(arguments[5])
} else {
    guard arguments.count == 4 else {
        fputs("usage: flatten-icon input output RRGGBB\n", stderr)
        exit(1)
    }
    inputPath = arguments[1]
    outputPath = arguments[2]
    edge = nil
    fallback = parseHex(arguments[3])
}

do {
    let source = try loadImage(inputPath)
    let width = edge ?? source.width
    let height = edge ?? source.height
    let rendered = try draw(source, width: width, height: height, fallback: fallback)
    let png = try pngData(width: width, height: height, rgb: rendered.rgb)
    try writeAtomically(png, to: outputPath)
    let check = try loadImage(outputPath)
    guard check.width == width, check.height == height else {
        throw Fail.message("could not re-read \(outputPath)")
    }
    let back = try draw(check, width: width, height: height, fallback: fallback)
    try assertSamePicture(rendered.rgb, back.rgb, width: width, height: height)
    let name = URL(fileURLWithPath: outputPath).lastPathComponent
    let mid = rendered.rgb[((height / 2) * width + (width / 2)) * 3..<(height / 2) * width * 3 + (width / 2) * 3 + 3]
    let corner = rendered.rgb[0..<3]
    print("flattened \(name) \(width)x\(height) backdrop=\(rendered.backdrop.hex) opaque=\(rendered.opaquePercent)% center=\(mid[mid.startIndex]),\(mid[mid.startIndex + 1]),\(mid[mid.startIndex + 2]) corner=\(corner[corner.startIndex]),\(corner[corner.startIndex + 1]),\(corner[corner.startIndex + 2])")
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
