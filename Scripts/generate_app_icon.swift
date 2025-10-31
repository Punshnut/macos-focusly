import AppKit
import Foundation

var pngCache: [CGFloat: Data] = [:]

struct IconEntry {
    let type: String
    let size: CGFloat
}

let entries: [IconEntry] = [
    IconEntry(type: "icp4", size: 16),
    IconEntry(type: "ic12", size: 32),   // 16pt @2x
    IconEntry(type: "icp5", size: 32),
    IconEntry(type: "ic11", size: 64),   // 32pt @2x
    IconEntry(type: "ic07", size: 128),
    IconEntry(type: "ic13", size: 256),  // 128pt @2x
    IconEntry(type: "ic08", size: 256),
    IconEntry(type: "ic14", size: 512),  // 256pt @2x
    IconEntry(type: "ic09", size: 512),
    IconEntry(type: "ic10", size: 1024)
]

func loadSourceImage(at path: String) -> NSImage {
    guard let image = NSImage(contentsOfFile: path) else {
        fatalError("Unable to load source image at \(path)")
    }
    return image
}

private func pngData(from image: NSImage, size: CGFloat) -> Data {
    if let cached = pngCache[size] {
        return cached
    }

    let targetSize = NSSize(width: size, height: size)
    let newImage = NSImage(size: targetSize)
    newImage.lockFocus()

    // Fill with a transparent background so PNGs retain an alpha channel.
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: targetSize).fill()

    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: targetSize),
               from: NSRect(origin: .zero, size: image.size),
               operation: .sourceOver,
               fraction: 1.0,
               respectFlipped: false,
               hints: [.interpolation: NSImageInterpolation.high])
    newImage.unlockFocus()

    guard
        let tiff = newImage.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Failed to create PNG representation for size \(size)")
    }

    pngCache[size] = png
    return png
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { buffer in
        data.append(contentsOf: buffer)
    }
}

func buildICNSData(from entries: [IconEntry], image: NSImage) -> Data {
    var chunks: [Data] = []
    var totalLength = 8 // icns header size

    for entry in entries {
        let png = pngData(from: image, size: entry.size)
        var chunk = Data()
        guard let typeData = entry.type.data(using: .macOSRoman) else {
            fatalError("Failed to encode icon type \(entry.type)")
        }
        chunk.append(typeData)
        appendUInt32BE(UInt32(png.count + 8), to: &chunk)
        chunk.append(png)
        chunks.append(chunk)
        totalLength += chunk.count
    }

    var icns = Data()
    icns.append("icns".data(using: .macOSRoman)!)
    appendUInt32BE(UInt32(totalLength), to: &icns)
    chunks.forEach { icns.append($0) }
    return icns
}

func writeICNS(from sourcePath: String, to destinationPath: String) {
    let image = loadSourceImage(at: sourcePath)
    let icnsData = buildICNSData(from: entries, image: image)
    let destinationURL = URL(fileURLWithPath: destinationPath)
    try! icnsData.write(to: destinationURL, options: .atomic)
}

// MARK: - Entry Point

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: generate_app_icon.swift <input.png> <output.icns>\n", stderr)
    exit(1)
}

writeICNS(from: arguments[1], to: arguments[2])
