import AppKit
import Foundation

struct IconGenerator {
    let outputURL: URL
    let fileManager = FileManager.default
    let sizes: [(name: String, points: CGFloat)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    func run() throws {
        let iconsetURL = outputURL.deletingPathExtension().appendingPathExtension("iconset")
        try? fileManager.removeItem(at: iconsetURL)
        try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

        for size in sizes {
            let image = renderIcon(size: size.points)
            let destination = iconsetURL.appendingPathComponent(size.name)
            try writePNG(image: image, to: destination)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "IconGenerator", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
        }

        try? fileManager.removeItem(at: iconsetURL)
    }

    private func renderIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSGraphicsContext.current?.imageInterpolation = .high

        let cornerRadius = size * 0.24
        let basePath = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04), xRadius: cornerRadius, yRadius: cornerRadius)
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.05, green: 0.16, blue: 0.14, alpha: 1),
            NSColor(calibratedRed: 0.11, green: 0.34, blue: 0.30, alpha: 1)
        ])!
        gradient.draw(in: basePath, angle: 90)

        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        basePath.lineWidth = max(2, size * 0.02)
        basePath.stroke()

        let innerRect = rect.insetBy(dx: size * 0.12, dy: size * 0.12)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: size * 0.18, yRadius: size * 0.18)
        NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
        innerPath.fill()

        let ringRect = rect.insetBy(dx: size * 0.2, dy: size * 0.2)
        let ringPath = NSBezierPath(ovalIn: ringRect)
        NSColor(calibratedRed: 0.52, green: 0.90, blue: 0.72, alpha: 0.2).setFill()
        ringPath.fill()

        if let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right.circle.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .bold)
            let symbolImage = symbol.withSymbolConfiguration(config) ?? symbol
            let symbolRect = NSRect(x: size * 0.24, y: size * 0.24, width: size * 0.52, height: size * 0.52)
            NSColor(calibratedRed: 0.95, green: 0.98, blue: 0.96, alpha: 1).set()
            symbolImage.draw(in: symbolRect)
        }

        let statusDotRect = NSRect(x: size * 0.69, y: size * 0.68, width: size * 0.14, height: size * 0.14)
        let statusDot = NSBezierPath(ovalIn: statusDotRect)
        NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.28, alpha: 1).setFill()
        statusDot.fill()
        NSColor(calibratedWhite: 0, alpha: 0.18).setStroke()
        statusDot.lineWidth = max(1, size * 0.01)
        statusDot.stroke()

        image.unlockFocus()
        return image
    }

    private func writePNG(image: NSImage, to destination: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render PNG"])
        }

        try pngData.write(to: destination)
    }
}

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 ? arguments[1] : "Resources/AppIcon.icns"
let outputURL = URL(fileURLWithPath: outputPath)

try IconGenerator(outputURL: outputURL).run()
