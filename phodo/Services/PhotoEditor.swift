import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Light edits only — framing, filters and fixes, no smoothing or face filters.
/// Edits are stored as settings and applied once when rendering, so the
/// preview and the posted photo always match.
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

    /// Filters, in the order the strip shows them.
    enum Mood: String, CaseIterable {
        case none, soft, film, faded, dusk, golden, cool, mono, noir
    }

    var quarterTurns = 0           // rotate 90° clockwise steps
    var aspect: Aspect = .original
    /// Pinch zoom inside the crop frame (1 = fills the frame).
    var zoom: CGFloat = 1
    /// Where the frame looks, -1...1 on each axis (0 = centered). y is screen-down.
    var pan: CGPoint = .zero
    var bright: Double = 0         // -0.3 ... 0.3
    var contrast: Double = 1       //  0.7 ... 1.3
    var warm: Double = 0           // -1 ... 1
    var mood: Mood = .none

    var isUnedited: Bool { self == EditSettings() }

    /// The framing part only (for showing "is this cropped?" and for resets).
    var isFramed: Bool { aspect != .original || zoom > 1.001 || pan != .zero }
}

enum PhotoEditor {
    static func render(_ image: CGImage, _ s: EditSettings) -> CGImage {
        guard !s.isUnedited else { return image }
        var ci = rotated(CIImage(cgImage: image), s.quarterTurns)
        ci = framed(ci, s)
        ci = filtered(ci, s.mood)
        ci = adjusted(ci, s)
        return PhotoProcessor.ciContext.createCGImage(ci, from: ci.extent.integral) ?? image
    }

    /// Everything except the framing — the editor shows this inside a frame and
    /// applies zoom / pan live, so pinching stays smooth.
    static func renderUnframed(_ image: CGImage, _ s: EditSettings) -> CGImage {
        var f = s
        f.aspect = .original; f.zoom = 1; f.pan = .zero
        return render(image, f)
    }

    /// Just rotation + one filter, for the little filter thumbnails.
    static func thumbnail(_ image: CGImage, turns: Int, mood: EditSettings.Mood) -> CGImage {
        var ci = rotated(CIImage(cgImage: image), turns)
        ci = filtered(ci, mood)
        return PhotoProcessor.ciContext.createCGImage(ci, from: ci.extent.integral) ?? image
    }

    /// height / width of the frame for these settings, given the (rotated) photo size.
    static func frameRatio(_ s: EditSettings, imageSize: CGSize) -> CGFloat {
        s.aspect.ratio ?? (imageSize.height / max(imageSize.width, 1))
    }

    // MARK: steps

    private static func rotated(_ ci: CIImage, _ turns: Int) -> CIImage {
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        let r = ci.oriented(orientations[((turns % 4) + 4) % 4])
        return r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY))
    }

    /// Crop to the frame's shape, zoomed in by `zoom`, looking at `pan`.
    /// Matches the editor: the photo fills the frame at zoom 1, then scales / slides.
    private static func framed(_ ci: CIImage, _ s: EditSettings) -> CIImage {
        guard s.isFramed else { return ci }
        let e = ci.extent
        let ratio = frameRatio(s, imageSize: e.size)
        // largest rect of that shape that fits, then shrink it by the zoom
        var w = e.width, h = e.width * ratio
        if h > e.height { h = e.height; w = h / ratio }
        let z = max(1, s.zoom)
        w /= z; h /= z
        let slackX = e.width - w, slackY = e.height - h
        let cx = e.midX + clamp(s.pan.x) * slackX / 2
        let cy = e.midY - clamp(s.pan.y) * slackY / 2          // CoreImage y goes up
        let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h).integral
        return ci.cropped(to: rect.intersection(e))
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    private static func filtered(_ ci: CIImage, _ mood: EditSettings.Mood) -> CIImage {
        switch mood {
        case .none: return ci
        case .soft:
            let f = CIFilter.colorControls()
            f.inputImage = ci; f.saturation = 0.85; f.brightness = 0.03; f.contrast = 0.92
            return f.outputImage ?? ci
        case .film:
            let f = CIFilter.photoEffectTransfer(); f.inputImage = ci; return f.outputImage ?? ci
        case .faded:
            let f = CIFilter.photoEffectFade(); f.inputImage = ci; return f.outputImage ?? ci
        case .dusk:     // phodo's own: a soft lavender evening wash
            return tint(ci, r: 1.02, g: 0.94, b: 1.10, lift: 0.03, saturation: 0.9)
        case .golden:
            return tint(ci, r: 1.10, g: 1.02, b: 0.86, lift: 0.02, saturation: 1.08)
        case .cool:
            return tint(ci, r: 0.92, g: 1.0, b: 1.10, lift: 0.0, saturation: 0.95)
        case .mono:
            let f = CIFilter.photoEffectMono(); f.inputImage = ci; return f.outputImage ?? ci
        case .noir:
            let f = CIFilter.photoEffectNoir(); f.inputImage = ci; return f.outputImage ?? ci
        }
    }

    private static func tint(_ ci: CIImage, r: CGFloat, g: CGFloat, b: CGFloat,
                             lift: CGFloat, saturation: Float) -> CIImage {
        let c = CIFilter.colorControls()
        c.inputImage = ci; c.saturation = saturation; c.brightness = 0; c.contrast = 1
        let m = CIFilter.colorMatrix()
        m.inputImage = c.outputImage ?? ci
        m.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
        m.biasVector = CIVector(x: lift, y: lift, z: lift, w: 0)
        return m.outputImage ?? ci
    }

    private static func adjusted(_ ci: CIImage, _ s: EditSettings) -> CIImage {
        var ci = ci
        if s.bright != 0 || s.contrast != 1 {
            let controls = CIFilter.colorControls()
            controls.inputImage = ci
            controls.brightness = Float(s.bright)
            controls.contrast = Float(s.contrast)
            controls.saturation = 1
            ci = controls.outputImage ?? ci
        }
        // warm: nudge red up / blue down (or the reverse)
        if s.warm != 0 {
            let m = CIFilter.colorMatrix()
            m.inputImage = ci
            m.rVector = CIVector(x: 1 + 0.12 * s.warm, y: 0, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: 1 - 0.12 * s.warm, w: 0)
            ci = m.outputImage ?? ci
        }
        return ci
    }

    private static func clamp(_ v: CGFloat) -> CGFloat { min(1, max(-1, v)) }
}
