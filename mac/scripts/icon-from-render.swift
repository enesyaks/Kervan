// Usage: swift scripts/icon-from-render.swift <render.png|jpg> Resources/AppIcon.png
// Cuts the rounded square out of a flat render (fake checkerboard behind it) and places it on a
// transparent 1024 canvas with macOS icon proportions: 824 pt squircle, 100 pt margin.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = CGImageSourceCreateWithURL(input as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let w = image.width, h = image.height

// Read pixels to find the blue squircle: blue clearly above red and above the gray/white checkerboard.
let bytesPerRow = w * 4
var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let reader = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: rgb,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
reader.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let i = y * bytesPerRow + x * 4
        let r = Int(pixels[i]), b = Int(pixels[i + 2])
        if b > r + 40 && b > 70 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
print("squircle bounds in source:", minX, minY, maxX, maxY)
// Step inside the edge so no checkerboard or drop shadow comes along; the new mask redraws the corners.
let inset = Int(Double(maxX - minX) * 0.012)
let crop = CGRect(x: minX + inset, y: minY + inset, width: maxX - minX - 2 * inset, height: maxY - minY - 2 * inset)
let art = image.cropping(to: crop)!

let canvas = 1024.0, size = 824.0, margin = (canvas - size) / 2
let writer = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
writer.interpolationQuality = .high
let rect = CGRect(x: margin, y: margin, width: size, height: size)
writer.addPath(CGPath(roundedRect: rect, cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil))
writer.clip()
writer.draw(art, in: rect)
let result = writer.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, result, nil)
CGImageDestinationFinalize(destination)
print("wrote", output.path)
