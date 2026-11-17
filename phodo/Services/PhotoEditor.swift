import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Light edits only — fixes and moods, no smoothing or face filters.
/// Edits are stored as settings and applied once when rendering.
struct EditSettings: Hashable {
    enum Aspect: String, CaseIterable {
        case original, square = "1:1", fourFive = "4:5", threeFour = "3:4"
        /// height / width
        var ratio: CGFloat? {
            switch self {
            case .original: nil
            case .square: 1
            case .fourFive: 5 / 4
            case .threeFour: 4 / 3
            }
        }
    }

    enum Mood: String, CaseIterable {
        case none, soft, film, faded
    }

    var quarterTurns = 0           // rotate 90° clockwise steps
    var aspect: Aspect = .original
    var bright: Double = 0         // -0.3 ... 0.3
    var contrast: Double = 1       //  0.7 ... 1.3
    var warm: Double = 0           // -1 ... 1
    var mood: Mood = .none

    var isUnedited: Bool { self == EditSettings() }
}

enum PhotoEditor {
    static func render(_ image: CGImage, _ s: EditSettings) -> CGImage {
        guard !s.isUnedited else { return image }
        var ci = CIImage(cgImage: image)

        // rotate
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        ci = ci.oriented(orientations[((s.quarterTurns % 4) + 4) % 4])
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))

        // center crop to aspect
        if let ratio = s.aspect.ratio {
            let e = ci.extent
            var w = e.width, h = e.width * ratio
            if h > e.height { h = e.height; w = h / ratio }
            ci = ci.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h).integral)
        }

        // mood presets
        switch s.mood {
        case .none: break
        case .soft:
            let f = CIFilter.colorControls()
            f.inputImage = ci; f.saturation = 0.85; f.brightness = 0.03; f.contrast = 0.92
            ci = f.outputImage ?? ci
        case .film:
            let f = CIFilter.photoEffectTransfer(); f.inputImage = ci; ci = f.outputImage ?? ci
        case .faded:
            let f = CIFilter.photoEffectFade(); f.inputImage = ci; ci = f.outputImage ?? ci
        }

        // bright + contrast
        let controls = CIFilter.colorControls()
        controls.inputImage = ci
        controls.brightness = Float(s.bright)
        controls.contrast = Float(s.contrast)
        controls.saturation = 1
        ci = controls.outputImage ?? ci

        // warm: nudge red up / blue down (or the reverse)
        if s.warm != 0 {
            let m = CIFilter.colorMatrix()
            m.inputImage = ci
            m.rVector = CIVector(x: 1 + 0.12 * s.warm, y: 0, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: 1 - 0.12 * s.warm, w: 0)
            ci = m.outputImage ?? ci
        }

        let ctx = PhotoProcessor.ciContext
        return ctx.createCGImage(ci, from: ci.extent.integral) ?? image
    }
}
