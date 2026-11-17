import CoreLocation
import ImageIO
import SwiftUI
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

    private func luminance(_ color: Color) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> Double { let c = Double(c); return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// WCAG: body text needs 4.5:1. Every preset, light and dark, must pass.
    func testEveryThemeIsReadable() {
        for preset in ThemePreset.all {
            let t = Theme(preset: preset)
            XCTAssertGreaterThanOrEqual(contrast(t.ink, t.bg), 7, "\(preset.id): ink on bg")
            XCTAssertGreaterThanOrEqual(contrast(t.softInk, t.bg), 4.5, "\(preset.id): softInk on bg")
            XCTAssertGreaterThanOrEqual(contrast(t.softInk, t.card), 4.5, "\(preset.id): softInk on card")
            XCTAssertGreaterThanOrEqual(contrast(t.bg, t.ink), 7, "\(preset.id): button text")
        }
    }

    func testDarkThemesAreSoftNotBlack() {
        for preset in ThemePreset.darks {
            let bg = luminance(Theme(preset: preset).bg)
            XCTAssertGreaterThan(bg, 0.02, "\(preset.id) background is too close to black")
        }
    }

    /// Renders real components in every theme into one image (for eyeballing).
    /// Path is printed in the test log: "theme gallery: …".
    @MainActor
    func testRenderThemeGallery() throws {
        struct Swatch: View {
            let preset: ThemePreset
            var body: some View {
                let t = Theme(preset: preset)
                VStack(alignment: .leading, spacing: 10) {
                    ScreenHeader(title: "today", trailing: preset.id)
                    PhotoTile(image: nil, aspect: 0.7)
                    Text("iced latte walk").font(PhFont.body(15)).foregroundStyle(t.ink)
                    Text("nov 16 · #coffee").font(PhFont.mono(11)).foregroundStyle(t.softInk)
                    HStack { TagChip(text: "#coffee", selected: true); TagChip(text: "#nap") }
                    Button("post it") {}.buttonStyle(PrimaryButtonStyle())
                }
                .padding(14).frame(width: 230)
                .background(t.bg)
                .environment(\.theme, t)
            }
        }
        let gallery = VStack(spacing: 0) {
            HStack(spacing: 0) { ForEach(ThemePreset.light) { Swatch(preset: $0) } }
            HStack(spacing: 0) { ForEach(ThemePreset.darks) { Swatch(preset: $0) } }
        }
        let renderer = ImageRenderer(content: gallery)
        renderer.scale = 2
        let data = try XCTUnwrap(renderer.uiImage?.pngData())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phodo-theme-gallery.png")
        try data.write(to: url)
        print("theme gallery: \(url.path)")
    }

    func testPresetIDsAreUnique() {
        XCTAssertEqual(Set(ThemePreset.all.map(\.id)).count, ThemePreset.all.count)
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
    private let me = SampleData.me

    private func draft(_ caption: String = "hi", day: LocalDay = .today, _ vis: PostVisibility = .friends) -> PostDraft {
        PostDraft(day: day, caption: caption, tags: [], visibility: vis, photo: nil)
    }

    func testSeveralPostsPerDayAllowed() async throws {
        let service = MockPostService(me: me, seed: false)
        _ = try await service.createPost(draft("one"), by: me)
        _ = try await service.createPost(draft("two"), by: me)
        let mine = try await service.myPosts(me)
        XCTAssertEqual(mine.filter { $0.day == .today }.count, 2)
    }

    func testCanFillInAMissedDay() async throws {
        let service = MockPostService(me: me, seed: false)
        let lastWeek = LocalDay.today.adding(days: -7)
        let post = try await service.createPost(draft(day: lastWeek), by: me)
        XCTAssertEqual(post.day, lastWeek)
    }

    func testCannotPostForTheFuture() async {
        let service = MockPostService(me: me, seed: false)
        do {
            _ = try await service.createPost(draft(day: LocalDay.today.adding(days: 1)), by: me)
            XCTFail("future post should fail")
        } catch {
            XCTAssertEqual(error as? PostError, .futureDay)
        }
    }

    func testEmptyPostRejected() async {
        let service = MockPostService(me: me, seed: false)
        do {
            _ = try await service.createPost(draft("  "), by: me)
            XCTFail("empty post should fail")
        } catch {
            XCTAssertEqual(error as? PostError, .empty)
        }
    }

    func testFeedOnlyShowsChosenPeopleAndHidesPrivate() async throws {
        let service = MockPostService(me: me, seed: false)
        let friend = SampleData.friends[0], stranger = SampleData.strangers[0]
        _ = try await service.createPost(draft("for friends"), by: friend)
        _ = try await service.createPost(draft("secret", .justMe), by: friend)
        _ = try await service.createPost(draft("hi world", .everyone), by: stranger)

        let feed = try await service.feed(from: [friend.id], since: Date().addingTimeInterval(-3600))
        XCTAssertEqual(feed.map(\.caption), ["for friends"])

        let explore = try await service.explore()
        XCTAssertEqual(explore.map(\.caption), ["hi world"])
    }
}

@MainActor
final class TagTests: XCTestCase {
    private func post(_ tags: [String], minutesAgo: Double) -> Post {
        var p = Post(id: UUID(), author: SampleData.me, day: .today, caption: "x", tags: tags,
                     visibility: .friends, image: nil, aspect: 1, tint: nil)
        p.createdAt = Date().addingTimeInterval(-minutesAgo * 60)
        return p
    }

    func testNewUserGetsFiveStarters() {
        XCTAssertEqual(AppStore.suggestedTags(from: []), Array(SampleData.starterTags.prefix(5)))
    }

    func testMostRecentFirstAndNeverMoreThanFive() {
        let posts = [post(["old1", "old2"], minutesAgo: 300),
                     post(["beach", "tacos", "beach"], minutesAgo: 5),
                     post(["gym", "rain", "late", "ramen"], minutesAgo: 60)]
        let tags = AppStore.suggestedTags(from: posts)
        XCTAssertEqual(tags, ["beach", "tacos", "gym", "rain", "late"])   // newest post first, no dupes
        XCTAssertEqual(tags.count, 5)
    }

    func testFewTagsTopUpWithStarters() {
        let tags = AppStore.suggestedTags(from: [post(["beach"], minutesAgo: 1)])
        XCTAssertEqual(tags.first, "beach")
        XCTAssertEqual(tags.count, 5)
    }
}

@MainActor
final class FriendTests: XCTestCase {
    func testRequestAcceptRemove() async throws {
        let social = MockSocialService(seed: false)
        let june = SampleData.strangers[0]
        try await social.request(june.id)
        var conns = try await social.connections()
        XCTAssertEqual(conns.first?.status, .outgoing)
        try await social.accept(june.id)
        conns = try await social.connections()
        XCTAssertEqual(conns.first?.status, .friends)
        try await social.remove(june.id)
        conns = try await social.connections()
        XCTAssertTrue(conns.isEmpty)
    }

    func testSearchByUsernamePrefix() async throws {
        let social = MockSocialService(seed: false)
        let found = try await social.search("Ju")
        XCTAssertEqual(found.map(\.username), ["june"])
        let none = try await social.search("")
        XCTAssertTrue(none.isEmpty)
    }

    func testLikeAndUnlike() async throws {
        let social = MockSocialService(seed: false)
        let post = UUID(), other = UUID()
        try await social.like(post)
        try await social.like(post)                          // liking twice is fine
        var info = try await social.likes(on: [post, other])
        XCTAssertEqual(info.mine, [post])
        try await social.unlike(post)
        info = try await social.likes(on: [post])
        XCTAssertTrue(info.mine.isEmpty)
    }

    func testBoardCanBeMadePublic() async throws {
        let social = MockSocialService(seed: false)
        let board = try await social.createBoard(named: "fits")
        XCTAssertFalse(board.isPublic)                       // private by default
        try await social.setBoardPublic(board.id, true)
        let boards = try await social.boards(of: UUID())
        XCTAssertEqual(boards.first?.isPublic, true)
    }

    func testBoardsSaveAndUnsave() async throws {
        let social = MockSocialService(seed: false)
        let board = try await social.createBoard(named: "cozy")
        let post = UUID()
        try await social.save(post, to: board.id)
        try await social.save(post, to: board.id)           // saving twice doesn't duplicate
        var boards = try await social.boards(of: UUID())
        XCTAssertEqual(boards.first?.postIDs, [post])
        try await social.unsave(post, from: board.id)
        boards = try await social.boards(of: UUID())
        XCTAssertEqual(boards.first?.postIDs, [])
    }
}
