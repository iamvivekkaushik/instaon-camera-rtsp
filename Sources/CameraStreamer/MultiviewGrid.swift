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
            let gap: CGFloat = 6
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

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.9))
                .allowsHitTesting(false)

            tileContent
        }
        .frame(width: width, height: height)
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
                        Label("Restart", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                            .font(.caption.weight(.semibold))
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Restart this channel")
                    .accessibilityLabel("Restart channel")
                    .disabled(isBusy)
                }
                statusDot
            }
            .padding(8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor : Color.white.opacity(0.12),
                    lineWidth: isFocused ? 2.5 : 1
                )
                .allowsHitTesting(false)
        )
        // Note: no auto-focus when playback starts — with multiview every ready tile
        // would steal focus (focus thrash). The engine picks the primary channel instead.
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
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            case .probing(let target):
                tappablePlaceholder { progress("Probing…", detail: target) }
            case .starting:
                tappablePlaceholder { progress("Starting…") }
            case .tunneling:
                tappablePlaceholder { progress("Opening tunnel…") }
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title2)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 10)
                    if onRestart != nil {
                        Button {
                            onRestart?()
                        } label: {
                            Label("Restart channel", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(isBusy)
                        .accessibilityLabel("Restart channel \(cell.channel)")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            case .idle:
                tappablePlaceholder {
                    idleSlot(channel: cell.channel, kind: .waiting)
                }
            case .off:
                idleSlot(channel: cell.channel, kind: .off)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            tappablePlaceholder {
                idleSlot(channel: nil, kind: .empty)
            }
        }
    }

    private func tappablePlaceholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
    }

    private var channelBadge: some View {
        Text(badge ?? (cell.map { "CH \($0.channel)" } ?? "—"))
            .lineLimit(1)
            .truncationMode(.middle)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel(cell.map { "Select channel \($0.channel)" } ?? "Empty slot")
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var statusDot: some View {
        if let cell {
            Circle()
                .fill(statusColor(for: cell.state))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
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
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(channel.map { "Channel \($0)" } ?? "Empty")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch kind {
            case .waiting:
                Text("Waiting…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .off:
                Text("Not selected")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .empty:
                EmptyView()
            }
        }
    }

    private func progress(_ title: String, detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
            }
        }
    }

    private func statusColor(for state: StreamEngine.State) -> Color {
        switch state {
        case .playing: return .green
        case .failed: return .orange
        case .idle, .off: return .gray
        case .starting, .probing, .tunneling: return .yellow
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
