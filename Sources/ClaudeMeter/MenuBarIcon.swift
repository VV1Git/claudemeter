import AppKit
import SwiftUI
import UsageCore

/// The ring drawn in the menu bar.
///
/// `MenuBarExtra`'s label only reliably renders `Text` and `Image`, so the ring is rasterised
/// into an `NSImage` instead of being a live SwiftUI shape. The image is deliberately *not* a
/// template image: the status bar re-tints templates monochrome, which would throw away the
/// amber and red the severity colour exists to communicate.
@MainActor
public enum MenuBarIcon {
    /// Point size of the rendered square image.
    public static let side: CGFloat = 18

    /// An `side`×`side` ring filled clockwise from 12 o'clock to `percent` (0–100), tinted by
    /// `severity`. `showsCapDot` adds a filled centre dot for `Projection.willCapEarly`.
    public static func image(percent: Double?, severity: Severity, showsCapDot: Bool) -> NSImage {
        let key = Key(
            percent: percent.map { Int(min(100, max(0, $0)).rounded()) },
            severity: severity,
            capDot: showsCapDot,
            dark: menuBarIsDark,
            scale: rasterScale,
            accent: accentComponents
        )
        if let cached = cache[key] { return cached }
        let rendered = render(key)
        cache[key] = rendered
        return rendered
    }

    /// 102 percentages × 3 severities × cap dot × appearance, times the one or two backing
    /// scales and accent colours a single machine ever reports, is a bounded key space of 18pt
    /// bitmaps, so there is nothing to evict.
    private static var cache: [Key: NSImage] = [:]

    /// Every input the bitmap bakes in — a dimension missing here is a stale ring. Without
    /// `severity` a window that crossed 90 would keep its green ring; without `dark` the track
    /// would stay black after a flip to dark mode; without `scale` a ring first drawn for a 1×
    /// display would stay soft after a Retina display is attached; without `accent` a `.normal`
    /// ring keeps the old system accent for every percentage already visited, so the icon
    /// alternates between two colours as the number moves.
    private struct Key: Hashable {
        let percent: Int?
        let severity: Severity
        let capDot: Bool
        let dark: Bool
        let scale: CGFloat
        let accent: Int
    }

    /// A rasterised image cannot re-resolve semantic colours when the appearance flips, so the
    /// appearance is part of the cache key and the label re-asks for the image on a change.
    private static var menuBarIsDark: Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The menu bar is drawn on *every* attached screen, so the sharpest one sets the
    /// resolution rather than whichever screen happens to be `NSScreen.main`: a 2× bitmap
    /// downsamples cleanly onto a 1× display, while a 1× bitmap on Retina is visibly soft.
    private static var rasterScale: CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    }

    /// The system accent packed as 8-bit sRGB. `SeverityStyle.color(.normal)` is
    /// `Color.accentColor`, which is resolved into the bitmap at rasterisation time, so the
    /// accent has to be keyed or a change in System Settings never reaches the cached rings.
    /// Nothing pushes the change: the label re-asks on its next tick, within 30s.
    private static var accentComponents: Int {
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return -1 }
        let red = Int((accent.redComponent * 255).rounded())
        let green = Int((accent.greenComponent * 255).rounded())
        let blue = Int((accent.blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }

    private static func render(_ key: Key) -> NSImage {
        let renderer = ImageRenderer(
            content: RingIcon(percent: key.percent, severity: key.severity, capDot: key.capDot)
                .environment(\.colorScheme, key.dark ? .dark : .light)
        )
        renderer.scale = key.scale
        // `ImageRenderer.nsImage` ignores `scale` — measured: it returns the same 36×36 bitmap
        // for `scale` 1, 2 and 3 — and it decides the point size itself. `cgImage` does honour
        // `scale`, so the pixels come from there and the point size is pinned here. That is what
        // keeps an @2× ring an 18pt item instead of a 36pt one, and what keeps it crisp when the
        // sharpest screen is not the main one.
        guard let bitmap = renderer.cgImage else {
            return NSImage(size: CGSize(width: side, height: side))
        }
        let image = NSImage(cgImage: bitmap, size: CGSize(width: side, height: side))
        image.isTemplate = false
        image.accessibilityDescription = accessibilityDescription(for: key)
        return image
    }

    private static func accessibilityDescription(for key: Key) -> String {
        guard let percent = key.percent else { return "Claude usage unavailable" }
        let pace = key.capDot ? ", on pace to run out before it resets" : ""
        return "Claude \(WindowKind.fiveHour.longLabel) usage \(percent) percent\(pace)"
    }
}

private struct RingIcon: View {
    let percent: Int?
    let severity: Severity
    let capDot: Bool

    private let lineWidth: CGFloat = 2.4

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.22), lineWidth: lineWidth)
            if let fraction, fraction > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if capDot {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(lineWidth / 2)
        .frame(width: MenuBarIcon.side, height: MenuBarIcon.side)
    }

    private var fraction: CGFloat? {
        percent.map { CGFloat(min(100, max(0, $0))) / 100 }
    }

    private var tint: Color { SeverityStyle.color(severity) }
}
