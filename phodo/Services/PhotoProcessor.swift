import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Everything the upload needs, produced on the phone before anything leaves it.
struct ProcessedPhoto {
    let fullJPEG: Data      // longest side ≤ 2048px
    let thumbJPEG: Data     // longest side ≤ 600px, used by the feed grid
    let width: Int
    let height: Int
    let tint: UIColor       // average color → placeholder while loading
    let preview: UIImage

    var aspect: CGFloat { CGFloat(height) / CGFloat(max(width, 1)) }
}

/// Step 2 of the photo pipeline: shrink + clean.
///
/// Re-encoding from a fresh CGImage writes **no metadata**, so EXIF/GPS from the
/// original photo never gets uploaded.
enum PhotoProcessor {
    static let fullMaxPixel = 2048
    static let thumbMaxPixel = 600
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Decode + downsample in one step (memory-cheap, applies EXIF rotation).
    static func downsample(_ data: Data, maxPixel: Int = fullMaxPixel) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Shrink an in-memory image (e.g. after editing).
    static func resize(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let scale = CGFloat(maxPixel) / CGFloat(longest)
        let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(scaled, from: scaled.extent.integral) ?? image
    }

    /// JPEG with no metadata.
    static func encodeJPEG(_ image: CGImage, quality: CGFloat = 0.8) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func averageColor(_ image: CGImage) -> UIColor {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return .lightGray }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    /// Final step before upload: the (already edited) image → full + thumb JPEGs.
    static func process(_ image: CGImage) -> ProcessedPhoto? {
        let full = resize(image, maxPixel: fullMaxPixel)
        let thumb = resize(full, maxPixel: thumbMaxPixel)
        guard let fullData = encodeJPEG(full), let thumbData = encodeJPEG(thumb, quality: 0.75) else { return nil }
        return ProcessedPhoto(fullJPEG: fullData, thumbJPEG: thumbData,
                              width: full.width, height: full.height,
                              tint: averageColor(thumb), preview: UIImage(cgImage: full))
    }
}
