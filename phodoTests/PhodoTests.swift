import CoreLocation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import phodo

final class PhotoProcessorTests: XCTestCase {
    /// A 4000x3000 JPEG with GPS metadata baked in — like a real iPhone photo.
    private func photoWithGPS() -> Data {
        let size = CGSize(width: 4000, height: 3000)
        let image = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in UIColor.systemPurple.setFill(); ctx.fill(CGRect(origin: .zero, size: size)) }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 29.42, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 98.49, kCGImagePropertyGPSLongitudeRef: "W"]
        CGImageDestinationAddImage(dest, image.cgImage!, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func properties(_ data: Data) -> [CFString: Any] {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    func testFixtureReallyHasGPS() {
        XCTAssertNotNil(properties(photoWithGPS())[kCGImagePropertyGPSDictionary])
    }

    func testProcessShrinksAndStripsGPS() throws {
        let base = try XCTUnwrap(PhotoProcessor.downsample(photoWithGPS()))
        let photo = try XCTUnwrap(PhotoProcessor.process(base))

        XCTAssertEqual(max(photo.width, photo.height), 2048)
        XCTAssertEqual(photo.aspect, 0.75, accuracy: 0.01)
        XCTAssertNil(properties(photo.fullJPEG)[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties(photo.thumbJPEG)[kCGImagePropertyGPSDictionary])

        let thumb = try XCTUnwrap(UIImage(data: photo.thumbJPEG))
        XCTAssertLessThanOrEqual(max(thumb.size.width, thumb.size.height), 600)
        XCTAssertLessThan(photo.fullJPEG.count, 1_500_000)
    }

    func testEditorCropsAndRotates() throws {
        let base = try XCTUnwrap(PhotoProcessor.downsample(photoWithGPS()))   // 2048 x 1536
        var s = EditSettings()
        s.aspect = .square
        let square = PhotoEditor.render(base, s)
        XCTAssertEqual(square.width, square.height)

        s = EditSettings(); s.quarterTurns = 1
        let turned = PhotoEditor.render(base, s)
        XCTAssertEqual(turned.width, base.height)
        XCTAssertEqual(turned.height, base.width)
    }
}

final class ThemeTests: XCTestCase {
    func testLavenderMatchesMockup() {
        let bg = UIColor(Theme(preset: .lavender).bg)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bg.getRed(&r, green: &g, blue: &b, alpha: &a)
        // #DCD5F5 = 220, 213, 245
        XCTAssertEqual(r * 255, 220, accuracy: 3)
        XCTAssertEqual(g * 255, 213, accuracy: 3)
        XCTAssertEqual(b * 255, 245, accuracy: 3)
    }
}

final class AccountRulesTests: XCTestCase {
    func testUsernameCleaning() {
        XCTAssertEqual(Username.clean("Cami Hart!"), "camihart")
        XCTAssertEqual(Username.clean("café_2.0"), "caf_2.0")      // non-ASCII dropped
        XCTAssertTrue(Username.isValid("cami_h"))
        XCTAssertFalse(Username.isValid("c"))                       // too short
        XCTAssertFalse(Username.isValid(String(repeating: "a", count: 25)))
        XCTAssertFalse(Username.isValid("Cami"))                     // must already be clean
    }

    func testAgeGate() {
        let now = Date()
        let cal = Calendar.current
        XCTAssertTrue(Age.isAtLeast13(birthday: cal.date(byAdding: .year, value: -13, to: now)!, now: now))
        XCTAssertFalse(Age.isAtLeast13(birthday: cal.date(byAdding: .day, value: 1,
                                                       to: cal.date(byAdding: .year, value: -13, to: now)!)!, now: now))
        XCTAssertFalse(Age.isAtLeast13(birthday: now, now: now))
    }

    func testLocalDayKeyRoundTrip() {
        let day = LocalDay(year: 2026, month: 3, day: 7)
        XCTAssertEqual(day.key, "2026-03-07")
        XCTAssertEqual(LocalDay(key: day.key), day)
        XCTAssertNil(LocalDay(key: "nope"))
    }

    func testStoragePathsAreLowercase() {
        let id = UUID()
        XCTAssertEqual(id.lower, id.lower.lowercased())
        XCTAssertNotEqual(id.lower, id.uuidString)    // uuidString is uppercase
    }
}

@MainActor
final class PostingTests: XCTestCase {
    func testOnlyOnePostPerDay() async throws {
        let me = SampleData.me
        let service = MockPostService(me: me, seed: false)
        let draft = PostDraft(caption: "hi", tags: [], visibility: .friends, photo: nil)

        _ = try await service.createPost(draft, by: me, on: .today)
        do {
            _ = try await service.createPost(draft, by: me, on: .today)
            XCTFail("second post should fail")
        } catch {
            XCTAssertEqual(error as? PostError, .alreadyPostedToday)
        }
        // tomorrow is fine
        _ = try await service.createPost(draft, by: me, on: LocalDay.today.adding(days: 1))
    }

    func testEmptyPostRejected() async {
        let service = MockPostService(me: SampleData.me, seed: false)
        do {
            _ = try await service.createPost(PostDraft(caption: "  ", tags: [], visibility: .friends, photo: nil),
                                             by: SampleData.me, on: .today)
            XCTFail("empty post should fail")
        } catch {
            XCTAssertEqual(error as? PostError, .empty)
        }
    }
}
