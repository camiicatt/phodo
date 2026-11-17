import AppKit
import CoreGraphics

// phodo app icon: a line-art cat curled up asleep in a little circle, on lavender.
// Usage: swift tools/icon.swift out.png
// Coordinates are top-left origin on a 1024 canvas.

let size = 1024
let out = CommandLine.arguments[1]

func c(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let lavender = c(0xDCD5F5), card = c(0xF3F0FD), tint = c(0xC4BAEA), ink = c(0x1C1A27)
let line: CGFloat = 24

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)
ctx.setFillColor(lavender); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.setStrokeColor(ink); ctx.setLineJoin(.round); ctx.setLineCap(.round)

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func draw(_ build: (CGMutablePath) -> Void, fill: CGColor? = nil, width: CGFloat = line) {
    let path = CGMutablePath(); build(path)
    ctx.addPath(path)
    ctx.setLineWidth(width)
    if let fill { ctx.setFillColor(fill); ctx.drawPath(using: .fillStroke) } else { ctx.strokePath() }
}

// the curled body: one round loaf
let body = CGRect(x: 222, y: 300, width: 600, height: 520)

// ears (behind the head), pointing up-right off the top of the curl
draw({ $0.addLines(between: [p(560, 360), p(586, 228), p(668, 318)]); $0.closeSubpath() }, fill: lavender)
draw({ $0.addLines(between: [p(694, 330), p(790, 250), p(782, 380)]); $0.closeSubpath() }, fill: lavender)

// body
draw({ $0.addEllipse(in: body) }, fill: lavender)

// head: tucked into the curl, upper right, resting on the body
let head = CGRect(x: 520, y: 312, width: 290, height: 250)
draw({ $0.addEllipse(in: head) }, fill: lavender)

// tail: one solid shape that starts at the back of the curl, wraps around the
// front, and ends in a rounded tip tucked under the chin
draw({
    $0.move(to: p(226, 600))                                   // on the body outline (hidden)
    $0.addLine(to: p(240, 652))
    $0.addCurve(to: p(560, 778), control1: p(290, 770), control2: p(430, 800))    // outer edge
    $0.addCurve(to: p(722, 606), control1: p(670, 756), control2: p(740, 680))
    $0.addQuadCurve(to: p(664, 596), control: p(700, 556))                       // rounded tip
    $0.addCurve(to: p(556, 708), control1: p(664, 650), control2: p(628, 704))    // inner edge
    $0.addCurve(to: p(226, 600), control1: p(420, 716), control2: p(300, 690))
    $0.closeSubpath()
}, fill: lavender)

// sleepy closed eyes (arcs curving down) and a tiny nose
ctx.setLineWidth(18)
for x in [610.0, 712.0] {
    ctx.beginPath()
    ctx.addArc(center: p(x, 430), radius: 30, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
    ctx.strokePath()
}
draw({ $0.addLines(between: [p(648, 478), p(676, 478), p(662, 494)]); $0.closeSubpath() }, fill: ink, width: 8)

// "z"
ctx.setLineWidth(16)
ctx.beginPath()
ctx.addLines(between: [p(816, 170), p(886, 170), p(816, 240), p(886, 240)])
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
