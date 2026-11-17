import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// Builds the phodo app icon from a hand-drawn sketch (black lines on white):
// white → lavender (see-through), black → phodo ink, lines slightly thickened,
// cropped to the drawing and centered.
// Usage: swift tools/icon-from-sketch.swift tools/art/cat-sketch.png out.png [thicken]

let args = CommandLine.arguments
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let thicken = args.count > 3 ? Double(args[3])! : 2.5

let size = 1024
let lavender = (r: 0xDC, g: 0xD5, b: 0xF5)
let ink = (r: 0x1C, g: 0x1A, b: 0x27)

guard let ns = NSImage(contentsOf: input), let src = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("can't read \(input.path)")
}

// 1. upscale smoothly, then thicken the dark lines (morphology "minimum" grows black)
let ctxCI = CIContext()
var image = CIImage(cgImage: src)
// flatten any transparency onto white first
image = image.composited(over: CIImage(color: .white).cropped(to: image.extent))
let scale = 3.0
let lanczos = CIFilter.lanczosScaleTransform()
lanczos.inputImage = image; lanczos.scale = Float(scale); lanczos.aspectRatio = 1
image = lanczos.outputImage!
let grow = CIFilter.morphologyMinimum()
grow.inputImage = image.clampedToExtent()     // clamp so the edges don't pull in black
grow.radius = Float(thicken)
image = grow.outputImage!.cropped(to: image.extent)
// soften the stair-steps from the morphology a touch
let blur = CIFilter.gaussianBlur()
blur.inputImage = image.clampedToExtent(); blur.radius = 1.2
image = blur.outputImage!.cropped(to: image.extent)

let w = Int(image.extent.width), h = Int(image.extent.height)
var px = [UInt8](repeating: 0, count: w * h * 4)
ctxCI.render(image, toBitmap: &px, rowBytes: w * 4, bounds: image.extent, format: .RGBA8,
             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

// 2. darkness → ink coverage, and find the drawing's bounding box
var alpha = [Double](repeating: 0, count: w * h)
var minX = w, minY = h, maxX = 0, maxY = 0
for i in 0..<(w * h) {
    let lum = (0.2126 * Double(px[i*4]) + 0.7152 * Double(px[i*4+1]) + 0.0722 * Double(px[i*4+2])) / 255
    let a = min(1, max(0, (0.88 - lum) / 0.55))     // white paper → 0, marker → 1
    alpha[i] = a
    let x = i % w, y = i / w
    let margin = Int(scale * 4)                    // ignore any scan border at the very edge
    if x < margin || y < margin || x >= w - margin || y >= h - margin { alpha[i] = 0; continue }
    if a > 0.5 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}

// 3. place the cropped drawing centered, ~80% of the icon wide
let cropW = maxX - minX + 1, cropH = maxY - minY + 1
let fit = min(0.80 * Double(size) / Double(cropW), 0.66 * Double(size) / Double(cropH))
let drawW = Double(cropW) * fit, drawH = Double(cropH) * fit
let originX = (Double(size) - drawW) / 2
let originY = (Double(size) - drawH) / 2 + Double(size) * 0.02   // sit a hair low, like it's resting

var out = [UInt8](repeating: 255, count: size * size * 4)
for y in 0..<size {
    for x in 0..<size {
        // map back into the source crop (bilinear)
        let sx = (Double(x) - originX) / fit + Double(minX)
        let sy = (Double(y) - originY) / fit + Double(minY)
        var a = 0.0
        if sx >= 0, sy >= 0, sx < Double(w - 1), sy < Double(h - 1) {
            let x0 = Int(sx), y0 = Int(sy), fx = sx - Double(x0), fy = sy - Double(y0)
            let a00 = alpha[y0 * w + x0], a10 = alpha[y0 * w + x0 + 1]
            let a01 = alpha[(y0 + 1) * w + x0], a11 = alpha[(y0 + 1) * w + x0 + 1]
            a = (a00 * (1 - fx) + a10 * fx) * (1 - fy) + (a01 * (1 - fx) + a11 * fx) * fy
        }
        let o = (y * size + x) * 4
        out[o]     = UInt8(Double(lavender.r) * (1 - a) + Double(ink.r) * a)
        out[o + 1] = UInt8(Double(lavender.g) * (1 - a) + Double(ink.g) * a)
        out[o + 2] = UInt8(Double(lavender.b) * (1 - a) + Double(ink.b) * a)
        out[o + 3] = 255
    }
}

let provider = CGDataProvider(data: Data(out) as CFData)!
let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
let rep = NSBitmapImageRep(cgImage: cg)
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("drawing \(cropW)x\(cropH)px → \(Int(drawW))x\(Int(drawH)) in a \(size) icon")
