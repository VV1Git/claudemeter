import SwiftUI

// MARK: - Collapsible panel section

/// A collapsible section whose entire header row toggles it, not just the chevron.
///
/// This replaces `DisclosureGroup`, which was the obvious choice and the wrong one. With a custom
/// label it hit-tests only the label's own glyphs, so an uppercase caption a few characters wide was
/// the whole target and the chevron did most of the work. Patching that from outside means adding a
/// tap gesture to the label and hoping the built-in handling does not also fire — two toggles cancel
/// out, and which you get is not something the API promises. Owning the control removes the
/// question, and makes the open/close animation something this file decides rather than inherits.
struct PanelSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    /// Short on purpose. The panel resizes — and in the two-column case the window resizes with it —
    /// so a long curve reads as lag rather than polish.
    ///
    /// Critically damped rather than eased, because this drives a *window* resize. An ease-in-out
    /// reversed mid-flight retargets by overshooting first — measured at 584pt heading out, then
    /// 651pt one frame after the reversal, then back — and a window that overshoots its final
    /// width can cross the threshold where AppKit re-anchors the panel (see
    /// `PanelView.reanchorsBetweenWidths`). A damped spring retargets from wherever it is. The
    /// ease-in half was wasted anyway: the movement was already committed to by the click.
    static var toggle: Animation { .smooth(duration: 0.3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Self.toggle) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        // Rotated rather than swapped for a second symbol, so the glyph keeps its
                        // metrics and the label beside it cannot shift as the section opens.
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Text(title)
                        .font(.caption)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)

                    // Claims the rest of the row so the target reaches the panel edge.
                    Spacer(minLength: 0)
                }
                // Without this the transparent space the `Spacer` created is not hit-testable, and
                // the row would still only respond over the glyphs.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isExpanded ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")

            if isExpanded {
                content()
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Animatable panel size

/// Sizes the panel by values SwiftUI drives through *layout*, one step per frame.
///
/// A plain `.frame(width:height:)` under `withAnimation` is not enough, and this is the whole
/// reason the column switch used to jump. `MenuBarExtra(.window)` is backed by an `NSPanel`
/// whose `contentView` is an `NSHostingView`, and that hosting view resizes the panel
/// synchronously from the layout pass — it does not poll, and it has no continuous mode. But
/// SwiftUI animates a built-in frame in the *render tree* without re-running the layout query,
/// so the hosting view is asked for a size exactly twice, before and after, and calls `setFrame`
/// once. Sampled at 240Hz, a `.frame(width:)` animation across the column switch produced a
/// single window frame; this modifier produces eleven across the same 0.18s.
///
/// `animatableData` is the mechanism: SwiftUI writes it every frame, which re-evaluates `body`,
/// which is a real layout invalidation, which the hosting view sees. Width and height travel as
/// one `AnimatablePair` so the two dimensions cannot drift apart — the window has to arrive at
/// its new shape at the same moment the content inside it does, or the columns visibly finish
/// before the frame they sit in.
///
/// Reaching for the `NSWindow` directly is the approach this replaces, and it does not merely
/// read worse — it cannot work. `window.animator().setFrame(…)` is always handed the frame the
/// window already has, because the hosting view resized it earlier in the same tick.
struct PanelSize: ViewModifier, Animatable {
    var width: CGFloat
    /// Zero means "not measured yet", which leaves the height unconstrained. Only ever zero
    /// before the first layout, and `.animation(_:value:)` does not fire on an initial value,
    /// so no animation ever interpolates towards it.
    var height: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(width, height) }
        set {
            width = newValue.first
            height = newValue.second
        }
    }

    /// Pinned top-leading, so the content stays against the edge the window grows away from and
    /// the second column is uncovered rather than slid into place.
    func body(content: Content) -> some View {
        content.frame(width: width, height: height > 0 ? height : nil, alignment: .topLeading)
    }
}
