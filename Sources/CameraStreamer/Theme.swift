import SwiftUI

/// Design tokens and reusable presentation components for a premium look.
enum Theme {
    // MARK: Surfaces
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.55)
    static let cardBackgroundStrong = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color(nsColor: .separatorColor).opacity(0.65)
    static let tileBackground = Color.black
    static let scrim = LinearGradient(
        colors: [Color.black.opacity(0.65), Color.black.opacity(0)],
        startPoint: .top, endPoint: .bottom
    )

    // MARK: Text
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: Accents
    static let accent = Color(nsColor: .controlAccentColor)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let neutral = Color(nsColor: .tertiaryLabelColor)

    static let accentGradient = LinearGradient(
        colors: [accent.opacity(0.9), accent],
        startPoint: .top, endPoint: .bottom
    )

    static func titleFont(_ size: CGFloat = 13, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Card container with a small header (icon + title + optional trailing control).
struct SectionCard<Trailing: View, Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                Text(title)
                    .font(Theme.titleFont())
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing
            }
            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
    }
}

extension SectionCard where Trailing == EmptyView {
    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, trailing: { EmptyView() }, content: content)
    }
}

/// Small colored dot + label chip used for live status.
struct StatusPill: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.7), radius: 3)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(color.opacity(0.14)))
        .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(0.3), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// Compact icon button used in the toolbar.
struct ToolbarIconButton: View {
    let systemImage: String
    let help: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? Theme.accent : Theme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isActive ? Color.clear : Theme.cardBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// App glyph shown on the left of the toolbar.
struct AppMarkBadge: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.accentGradient)
            Image(systemName: "video.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
        .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
        .accessibilityHidden(true)
    }
}

/// Subtle section caption used inside cards.
struct CardCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
