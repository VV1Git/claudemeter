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
    static var toggle: Animation { .easeInOut(duration: 0.18) }

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
