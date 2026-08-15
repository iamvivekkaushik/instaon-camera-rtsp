import SwiftUI

struct MultiviewGrid: View {
    let cells: [StreamEngine.ChannelCell]
    let capacity: Int
    /// Slot-index based (channels repeat across devices in the custom view).
    let focusedSlot: Int?
    let onFocus: (Int) -> Void
    var onRestart: ((Int) -> Void)? = nil
    /// Optional per-slot badge text (e.g. "Front Door · CH 3" in the custom view).
    var badges: [String]? = nil

    private var columns: Int {
        switch capacity {
        case 1: return 1
        case 4: return 2
        default: return 3
        }
    }

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 8
            let colCount = CGFloat(columns)
            let rowCount = CGFloat(max(1, Int(ceil(Double(capacity) / Double(columns)))))
            let cellW = max(80, (geo.size.width - gap * (colCount - 1)) / colCount)
            let cellH = max(60, (geo.size.height - gap * (rowCount - 1)) / rowCount)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(cellW), spacing: gap), count: columns),
                spacing: gap
            ) {
                ForEach(0..<capacity, id: \.self) { index in
                    let cell = index < cells.count ? cells[index] : nil
                    let badge = badges.flatMap { index < $0.count ? $0[index] : nil }
                    ChannelTile(
                        cell: cell,
                        badge: badge,
                        isFocused: index == focusedSlot,
                        width: cellW,
                        height: cellH,
                        onSelect: { onFocus(index) },
                        onRestart: { onRestart?(index) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera multiview grid")
    }
}

struct ChannelTile: View {
    let cell: StreamEngine.ChannelCell?
    /// Custom badge text; defaults to "CH <n>".
    var badge: String? = nil
    let isFocused: Bool
    let width: CGFloat
    let height: CGFloat
    let onSelect: () -> Void
    var onRestart: (() -> Void)? = nil

    @State private var isHovering = false

    private var isPlaying: Bool {
        if case .playing = cell?.state { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = cell?.state { return true }
        return false
    }

    private var isBusy: Bool {
        switch cell?.state {
        case .starting, .probing, .tunneling: return true
        default: return false
        }
    }

    /// Show the small restart icon on every live tile (not just failed ones).
    private var showRestart: Bool {
        guard onRestart != nil, let cell else { return false }
        if case .off = cell.state { return false }
        return true
    }

    private var stateColor: Color {
        guard let cell else { return Theme.neutral }
        switch cell.state {
        case .playing: return Theme.success
        case .failed: return Theme.warning
        case .idle, .off: return Theme.neutral
        case .starting, .probing, .tunneling: return Theme.accent
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.tileBackground)
                .allowsHitTesting(false)

            tileContent

            // Scrim on the top edge so the badge stays legible over video.
            if isPlaying {
                VStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.scrim)
                        .frame(height: 36)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topLeading) {
            channelBadge
                .padding(8)
                .onTapGesture(perform: onSelect)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if showRestart {
                    Button {
                        onRestart?()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.ultraThinMaterial))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering || isFailed ? 1 : 0.55)
                    .help("Restart this channel")
                    .accessibilityLabel("Restart channel")
                    .disabled(isBusy)
                }
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: stateColor.opacity(0.8), radius: 3)
                    .accessibilityHidden(true)
            }
            .padding(8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isFocused ? Theme.accent : Color.white.opacity(isHovering ? 0.22 : 0.10),
                    lineWidth: isFocused ? 2.5 : 1
                )
                .shadow(color: isFocused ? Theme.accent.opacity(0.35) : .clear, radius: 8)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .accessibilityAction(named: "Select channel", onSelect)
        .accessibilityAction(named: "Restart channel") {
            onRestart?()
        }
    }

    private var accessibilityHint: String {
        if isFailed { return "Double-click or use Restart to try again" }
        if isPlaying { return "Use player controls for playback and full screen" }
        return "Select this camera channel"
    }

    @ViewBuilder
    private var tileContent: some View {
        if let cell {
            switch cell.state {
            case .playing(let url):
                PlayerView(url: url)
            case .probing(let target):
                tappablePlaceholder { progress("Connecting…", detail: target) }
            case .starting:
                tappablePlaceholder { progress("Starting…") }
            case .tunneling:
                tappablePlaceholder { progress("Opening tunnel…") }
            case .failed(let message):
                failedContent(cell: cell, message: message)
            case .idle:
                tappablePlaceholder {
                    idleSlot(channel: cell.channel, kind: .waiting)
                }
            case .off:
                idleSlot(channel: cell.channel, kind: .off)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            idleSlot(channel: nil, kind: .empty)
        }
    }

    private func failedContent(cell: StreamEngine.ChannelCell, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .font(.title2)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption2)
                .foregroundStyle(Theme.warning)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 10)
            if onRestart != nil {
                Button {
                    onRestart?()
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
                .accessibilityLabel("Restart channel \(cell.channel)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func tappablePlaceholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
    }

    private var channelBadge: some View {
        Text(badge ?? (cell.map { "CH \($0.channel)" } ?? "—"))
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .accessibilityLabel(cell.map { "Select channel \($0.channel)" } ?? "Empty slot")
            .accessibilityAddTraits(.isButton)
    }

    private enum IdleKind {
        case waiting
        case empty
        case off
    }

    private func idleSlot(channel: Int?, kind: IdleKind) -> some View {
        VStack(spacing: 8) {
            Image(systemName: kind == .off ? "video.slash" : "video")
                .font(.title2)
                .foregroundStyle(Theme.neutral)
                .accessibilityHidden(true)
            Text(channel.map { "Channel \($0)" } ?? "Empty")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            switch kind {
            case .waiting:
                Text("Ready · press Start")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            case .off:
                Text("Not selected")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            case .empty:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    kind == .empty ? Theme.neutral.opacity(0.35) : Color.clear,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private func progress(_ title: String, detail: String? = nil) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .tint(Theme.accent)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            if let detail {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var accessibilityLabelText: String {
        guard let cell else { return "Empty multiview slot" }
        let status: String
        switch cell.state {
        case .playing: status = "playing"
        case .failed: status = "failed"
        case .idle: status = "idle"
        case .off: status = "not selected"
        case .starting: status = "starting"
        case .probing: status = "probing"
        case .tunneling: status = "tunneling"
        }
        return "Channel \(cell.channel), \(status)"
    }
}

/// Placeholder cell used when a slot is unchecked / not playing.
extension StreamEngine.ChannelCell {
    static func off(channel: Int) -> StreamEngine.ChannelCell {
        StreamEngine.ChannelCell(channel: channel, state: .off, activeRTSP: "")
    }
}
