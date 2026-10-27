import AppKit
import ImageIO
import SwiftUI

/// States the mascot animates between. `CleaningSession.mascotState` drives them.
nonisolated enum MascotState: Equatable, Sendable {
    case idle
    /// Session running, nothing happening.
    case cleaning
    /// Briefly entered whenever blocked input is swallowed.
    case reactingToBlockedInput
    /// The unlock chord is being held.
    case wakingUp
    case finished
}

/// A sprite sheet bundled as a plain PNG in `Sweep/Resources/Mascot/`.
///
/// Frames are read left to right, top to bottom. With `columns`/`rows` left nil the sheet
/// is one horizontal strip of square frames. Multi-direction sheets use a single `row`.
nonisolated struct MascotAnimation: Sendable {
    let file: String
    var columns: Int?
    var rows: Int?
    /// Only this row is played (0 = facing the viewer in the cleaning sheet).
    var row: Int?
    var fps: Double
}

extension MascotState {
    /// Two sheets: sleeping while the app is open, cleaning during a session. Reactions to
    /// blocked input and waking up add a small code-driven hop on top of the cleaning loop.
    var animation: MascotAnimation {
        switch self {
        case .idle:
            MascotAnimation(file: "Sleep-Anim", fps: 1.6)
        case .cleaning, .reactingToBlockedInput, .wakingUp, .finished:
            MascotAnimation(file: "clean", columns: 4, rows: 8, row: 0, fps: 8)
        }
    }
}

/// The animated character. Renders nothing until its sprite sheet is bundled.
///
/// `size` is the on-screen size of a 40-pixel frame; every sheet is drawn at the same
/// points-per-pixel so the character keeps its size across animations. The view hugs the
/// drawn character, and its bottom edge is where the feet are.
struct MascotView: View {
    let state: MascotState
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let referenceFramePixels: CGFloat = 40

    static var hasSprites: Bool { SpriteSheet.load(MascotState.idle.animation) != nil }

    var body: some View {
        if let sheet = SpriteSheet.load(state.animation) ?? SpriteSheet.load(MascotState.idle.animation) {
            SpriteAnimationView(sheet: sheet, pointsPerPixel: size / Self.referenceFramePixels)
                .offset(y: hops && !reduceMotion ? -size * 0.06 : 0)
                .animation(hops ? Theme.Motion.celebrate : Theme.Motion.snappy, value: hops)
                .accessibilityHidden(true)
        }
    }

    private var hops: Bool {
        state == .reactingToBlockedInput || state == .wakingUp || state == .finished
    }
}

/// Frames cut once at full resolution and cached.
private final class SpriteSheet {
    let frames: [CGImage]
    let fps: Double
    let frameSize: CGSize
    /// Pixel rows below the lowest opaque pixel (the feet) in any frame.
    let emptyRowsBelowFeet: Int
    /// Rows from the highest opaque pixel to the feet across all frames.
    let contentRows: Int

    private static var cache: [String: SpriteSheet?] = [:]

    private init(frames: [CGImage], fps: Double) {
        self.frames = frames
        self.fps = fps
        frameSize = CGSize(width: frames[0].width, height: frames[0].height)
        let bounds = frames.map(Self.opaqueRows)
        let lowest = bounds.map(\.upperBound).max() ?? (frames[0].height - 1)
        let highest = bounds.map(\.lowerBound).min() ?? 0
        emptyRowsBelowFeet = frames[0].height - 1 - lowest
        contentRows = lowest - highest + 1
    }

    static func load(_ animation: MascotAnimation) -> SpriteSheet? {
        if let cached = cache[animation.file] { return cached }
        let sheet = make(animation)
        cache[animation.file] = sheet
        return sheet
    }

    private static func make(_ animation: MascotAnimation) -> SpriteSheet? {
        // ImageIO keeps the exact pixel dimensions (NSImage would apply the file's DPI).
        guard let url = Bundle.main.url(forResource: animation.file, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let columns = animation.columns ?? max(image.width / max(image.height, 1), 1)
        let rows = animation.rows ?? 1
        let width = image.width / columns
        let height = image.height / rows
        let rowRange = animation.row.map { [$0] } ?? Array(0..<rows)
        let frames = rowRange.flatMap { row in
            (0..<columns).compactMap { column in
                image.cropping(to: CGRect(x: column * width, y: row * height, width: width, height: height))
            }
        }
        return frames.isEmpty ? nil : SpriteSheet(frames: frames, fps: animation.fps)
    }

    /// First and last pixel rows containing anything opaque.
    private static func opaqueRows(_ image: CGImage) -> ClosedRange<Int> {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0...(height - 1) }
        // The bitmap's first row in memory is the image's top row.
        let opaque = (0..<height).filter { row in
            (0..<width).contains { pixels[(row * width + $0) * 4 + 3] > 0 }
        }
        guard let first = opaque.first, let last = opaque.last else { return 0...(height - 1) }
        return first...last
    }
}

/// Pixel art enlarged by whole device pixels per sprite pixel, never smoothed, so it
/// stays perfectly sharp on Retina displays.
private struct SpriteAnimationView: View {
    let sheet: SpriteSheet
    let pointsPerPixel: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var start = Date()

    var body: some View {
        let pixel = snappedPixel
        TimelineView(.animation(minimumInterval: 1 / sheet.fps, paused: reduceMotion || sheet.frames.count < 2)) { context in
            let elapsed = Int(context.date.timeIntervalSince(start) * sheet.fps)
            let index = reduceMotion ? 0 : elapsed % sheet.frames.count
            Image(decorative: sheet.frames[index], scale: 1)
                .resizable()
                .interpolation(.none)
                .antialiased(false)
                .frame(width: sheet.frameSize.width * pixel, height: sheet.frameSize.height * pixel)
        }
        // Feet on the bottom edge; the view is only as tall as the drawn character.
        .offset(y: CGFloat(sheet.emptyRowsBelowFeet) * pixel)
        .frame(width: sheet.frameSize.width * pixel, height: CGFloat(sheet.contentRows) * pixel, alignment: .bottom)
    }

    /// Points per sprite pixel, rounded to whole device pixels.
    private var snappedPixel: CGFloat {
        max(floor(pointsPerPixel * displayScale), 1) / displayScale
    }
}
