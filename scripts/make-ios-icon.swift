// Turns the icon artwork (a rounded tile drawn on a blurred backdrop) into a full-bleed iOS app icon:
//   swift scripts/make-ios-icon.swift <artwork.jpg> Platforms/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// iOS rounds the corners and adds its own edge highlights, so the tile's border, glow and backdrop are cropped away;
// what's left is the dark panel with the controller, scaled to 1024 px, opaque.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!, 0, nil)!
let w = img.width, h = img.height
var src = [UInt8](repeating: 0, count: w * h * 4)
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.noneSkipLast.rawValue
src.withUnsafeMutableBytes { p in
    CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: rgb, bitmapInfo: info)!
        .draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
}

// A square inside the panel, clear of the green border, its glow and its rounded corners, with the controller
// and the signal arcs roughly centred (measured on the 1024 px artwork).
let left = 252, top = 212, side = 520
var crop = [UInt8](repeating: 255, count: side * side * 4)
for y in 0..<side {
    for x in 0..<side {
        let s = ((top + y) * w + left + x) * 4, d = (y * side + x) * 4
        crop[d] = src[s]; crop[d + 1] = src[s + 1]; crop[d + 2] = src[s + 2]
    }
}
let cropImage = crop.withUnsafeMutableBytes { p in
    CGContext(data: p.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: rgb, bitmapInfo: info)!.makeImage()!
}
let out = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: rgb, bitmapInfo: info)!
out.interpolationQuality = .high
out.draw(cropImage, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
