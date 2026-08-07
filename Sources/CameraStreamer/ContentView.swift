import SwiftUI

struct ContentView: View {
    @StateObject private var stream = StreamEngine()
    @ObservedObject private var settings = AppSettings.shared

    @State private var device: DeviceLookupResult?
    @State private var isLookingUp = false
    @State private var statusMessage =
        "Enter device credentials, pick channels, then Start. Credentials are saved in Settings."
    @State private var showPassword = false
    @State private var showSettings = false
    @State private var focusedChannel: Int?
    @State private var channelDrafts: [String] = []

    private let client = InstaOnClient()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

            Divider()

            HSplitView {
                controlPanel
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)

                videoPanel
                    .frame(minWidth: 520)
            }
            .padding(12)

            if settings.showLogs {
                Divider()
                logPanel
                    .frame(minHeight: 140, idealHeight: 180, maxHeight: 260)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.22), value: settings.showLogs)
        .onAppear {
            settings.ensureChannelSlots(count: settings.gridCapacity)
            syncChannelDrafts()
            stream.mode = settings.streamMode
        }
        .onChange(of: settings.gridCapacity) { capacity in
            settings.ensureChannelSlots(count: capacity)
            syncChannelDrafts()
        }
        .onChange(of: settings.channels) { _ in
            syncChannelDrafts()
        }
        .onChange(of: settings.streamMode) { mode in
            stream.mode = mode
        }
        .onDisappear { stream.stop() }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(.headline)
                    Spacer()
                    Button("Done") { showSettings = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
                Divider()
                SettingsView(settings: settings)
            }
            .frame(minWidth: 460, minHeight: 420)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CameraStreamer")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(toolbarSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            layoutPicker
                .frame(maxWidth: 220)

            Toggle(isOn: $settings.showLogs) {
                Label(
                    settings.showLogs ? "Hide Logs" : "Show Logs",
                    systemImage: settings.showLogs ? "doc.text.fill" : "doc.text"
                )
            }
            .toggleStyle(.button)
            .help("Show or hide diagnostic logs")
            .accessibilityLabel(settings.showLogs ? "Hide logs" : "Show logs")

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Saved credentials and defaults")
            .accessibilityLabel("Open settings")
        }
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: $settings.gridCapacity) {
            Text("1×1").tag(1)
            Text("2×2").tag(4)
            Text("3×3").tag(9)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Multiview layout")
        .help("Number of camera tiles")
    }

    // MARK: - Control panel

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledField("InstaOn ID", accessibility: "Device serial") {
                            TextField("2009011801001104", text: $settings.serial)
                                .textFieldStyle(.roundedBorder)
                        }
                        labeledField("Username", accessibility: "Device username") {
                            TextField("admin", text: $settings.username)
                                .textFieldStyle(.roundedBorder)
                        }
                        labeledField("Password", accessibility: "Device password") {
                            HStack(spacing: 6) {
                                Group {
                                    if showPassword {
                                        TextField("Device password", text: $settings.password)
                                    } else {
                                        SecureField("Device password", text: $settings.password)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)

                                Toggle(isOn: $showPassword) {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                }
                                .toggleStyle(.button)
                                .buttonStyle(.borderless)
                                .help(showPassword ? "Hide password" : "Show password")
                                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                            }
                        }

                        Text("Saved automatically for next launch.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                } label: {
                    Label("Device", systemImage: "video.fill")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Channels in grid")
                                .font(.subheadline.weight(.medium))
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button("All") { settings.setAllSlotsEnabled(true) }
                                .controlSize(.small)
                                .help("Enable all slots for playback")
                            Button("None") { settings.setAllSlotsEnabled(false) }
                                .controlSize(.small)
                                .help("Disable all slots")
                        }

                        Text("Check Play for each slot included when you press Start.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        channelEditors

                        HStack {
                            Picker("Stream", selection: $settings.subtype) {
                                Text("Sub").tag(1)
                                Text("Main").tag(0)
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("Stream quality Main or Sub")
                            .help("Sub is more reliable over P2P, especially in multiview")
                        }

                        Picker("Mode", selection: $settings.streamMode) {
                            ForEach(StreamMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .accessibilityLabel("Connection mode")
                    }
                    .padding(4)
                } label: {
                    Label("Multiview", systemImage: "square.grid.2x2")
                }

                actionButtons

                if let device {
                    GroupBox {
                        Text(device.summary)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                            .accessibilityLabel("Device lookup result")
                    } label: {
                        Label("Lookup", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                GroupBox {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(4)
                        .accessibilityLabel("Status")
                        .accessibilityValue(statusMessage)
                } label: {
                    Label("Status", systemImage: "info.circle")
                }

                Text("Close gCMOB while streaming. Prefer Sub for multiview. Check Play only for cameras you want; use Restart on a failed tile.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 4)
        }
    }

    private var channelEditors: some View {
        let count = settings.gridCapacity
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: 10)],
                spacing: 10
            ) {
                ForEach(0..<count, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Slot \(index + 1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Toggle(
                                "Play",
                                isOn: bindingForSlotEnabled(index)
                            )
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help("Include this channel when starting")
                            .accessibilityLabel("Play channel slot \(index + 1)")

                            TextField(
                                "CH",
                                text: bindingForChannelDraft(index)
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 64)
                            .accessibilityLabel("Channel number for slot \(index + 1)")
                            .onSubmit { commitChannelDrafts() }

                            Text("Play")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                    )
                }
            }
        }
        .onDisappear { commitChannelDrafts() }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                commitChannelDrafts()
                Task { await lookup() }
            } label: {
                if isLookingUp {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 10)
                } else {
                    Text("Look Up")
                }
            }
            .disabled(isLookingUp || serialTrimmed.isEmpty)
            .keyboardShortcut("l", modifiers: [.command])
            .help("Query InstaOn for device metadata")
            .accessibilityLabel("Look up device")

            Button("Start") {
                commitChannelDrafts()
                Task { await startStream() }
            }
            .disabled(!canStart)
            .keyboardShortcut(.defaultAction)
            .help("Start multiview for configured channels")
            .accessibilityLabel("Start stream")

            Button("Stop") {
                stream.stop()
                statusMessage = "Stopped."
            }
            .disabled(!stream.isBusy && !stream.isPlaying)
            .keyboardShortcut(".", modifiers: [.command])
            .help("Stop all streams and tunnel")
            .accessibilityLabel("Stop stream")
        }
        .controlSize(.large)
    }

    // MARK: - Video

    private var videoPanel: some View {
        VStack(spacing: 8) {
            MultiviewGrid(
                cells: displayCells,
                capacity: settings.gridCapacity,
                focusedChannel: stream.liveChannel ?? focusedChannel,
                onFocus: { channel in
                    focusedChannel = channel
                    Task { await selectChannel(channel) }
                },
                onRestart: { channel in
                    focusedChannel = channel
                    Task { await restartChannel(channel) }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )
            .padding(2)

            if !stream.activeRTSP.isEmpty {
                Text(stream.activeRTSP)
                    .font(.caption2.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Active RTSP URL")
            }
        }
        .padding(4)
        .accessibilityElement(children: .contain)
    }

    /// Grid slots: live engine cells for checked channels; placeholders for unchecked.
    private var displayCells: [StreamEngine.ChannelCell] {
        let grid = settings.gridChannels
        let enabled = Array(settings.channelEnabled.prefix(settings.gridCapacity))
        return grid.enumerated().map { index, channel in
            let isOn = index < enabled.count ? enabled[index] : true
            if !isOn {
                return StreamEngine.ChannelCell(channel: channel, state: .idle, activeRTSP: "")
            }
            if let live = stream.cells.first(where: { $0.channel == channel }) {
                return live
            }
            return StreamEngine.ChannelCell(channel: channel, state: .idle, activeRTSP: "")
        }
    }

    // MARK: - Logs

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Logs", systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    settings.showLogs = false
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Hide logs")
                .accessibilityLabel("Hide logs")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(statusText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .id("logBottom")
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .onChange(of: stream.logLines.count) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
            .accessibilityLabel("Diagnostic log output")
            .accessibilityValue(statusText)
        }
        .background(.bar)
    }

    // MARK: - Helpers

    private func labeledField<Content: View>(
        _ title: String,
        accessibility: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .accessibilityLabel(accessibility)
        }
    }

    private var serialTrimmed: String {
        settings.serial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStart: Bool {
        !settings.password.isEmpty
            && !stream.isBusy
            && (!serialTrimmed.isEmpty || device != nil)
            && !settings.channelsToPlay.isEmpty
    }

    private var toolbarSubtitle: String {
        let sn = settings.serial.trimmingCharacters(in: .whitespacesAndNewlines)
        if sn.isEmpty { return "Configure device credentials to stream" }
        let ch = settings.channelsToPlay.map(String.init).joined(separator: ", ")
        let label = ch.isEmpty ? "none" : ch
        return "\(sn)  ·  Play CH \(label)  ·  \(settings.streamMode.rawValue)"
    }

    private var statusText: String {
        var lines = [statusMessage]
        if !stream.logLines.isEmpty {
            lines.append("")
            lines.append(contentsOf: stream.logLines.suffix(80))
        }
        return lines.joined(separator: "\n")
    }

    private func syncChannelDrafts() {
        let grid = settings.gridChannels
        channelDrafts = grid.map(String.init)
        while channelDrafts.count < settings.gridCapacity {
            channelDrafts.append(String(channelDrafts.count + 1))
        }
        if channelDrafts.count > settings.gridCapacity {
            channelDrafts = Array(channelDrafts.prefix(settings.gridCapacity))
        }
    }

    private func bindingForSlotEnabled(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { settings.isSlotEnabled(index) },
            set: { settings.setSlotEnabled(index, $0) }
        )
    }

    private func bindingForChannelDraft(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                if index < channelDrafts.count {
                    return channelDrafts[index]
                }
                return ""
            },
            set: { newValue in
                var drafts = channelDrafts
                while drafts.count <= index {
                    drafts.append("")
                }
                drafts[index] = newValue.filter(\.isNumber)
                channelDrafts = drafts
                // Live-commit valid channel numbers for grid labels.
                if let value = Int(drafts[index]), (1...64).contains(value) {
                    settings.setChannel(at: index, to: value)
                }
            }
        )
    }

    private func commitChannelDrafts() {
        var next: [Int] = []
        for index in 0..<settings.gridCapacity {
            let raw = index < channelDrafts.count ? channelDrafts[index] : ""
            if let value = Int(raw), (1...64).contains(value) {
                next.append(value)
            } else if index < settings.channels.count {
                next.append(settings.channels[index])
            } else {
                next.append(index + 1)
            }
        }
        settings.channels = next
        settings.ensureChannelSlots(count: settings.gridCapacity)
        syncChannelDrafts()
    }

    private func lookup() async {
        isLookingUp = true
        statusMessage = "Querying InstaOn…"
        defer { isLookingUp = false }
        do {
            let result = try await client.lookupDevice(serial: serialTrimmed)
            device = result
            statusMessage = "Lookup OK — \(result.ipAddress) (RTSP \(result.rtspPort), P2P \(result.p2pPort))"
        } catch {
            device = nil
            statusMessage = error.localizedDescription
            if !settings.showLogs {
                settings.showLogs = true
            }
        }
    }

    private func startStream() async {
        commitChannelDrafts()
        let channels = settings.channelsToPlay
        guard !channels.isEmpty else {
            statusMessage = "Check Play for at least one channel slot."
            return
        }

        let sn = serialTrimmed
        let target = device ?? DeviceLookupResult(
            serial: sn,
            ipAddress: "",
            p2pPort: 25001,
            httpPort: 80,
            rtspPort: 554,
            deviceType: "unknown",
            manufacturer: "unknown",
            visit: "p2p",
            p2pType: "dhp2p",
            softwareVersion: "",
            rawJSON: "{}"
        )
        guard !target.serial.isEmpty else { return }

        stream.mode = settings.streamMode
        let preferred = focusedChannel.flatMap { channels.contains($0) ? $0 : nil } ?? channels.first
        focusedChannel = preferred
        statusMessage = "Starting \(settings.streamMode.rawValue) for \(channels.count) channel(s)…"

        await stream.start(
            device: target,
            username: settings.username,
            password: settings.password,
            channels: channels,
            subtype: settings.subtype,
            preferredChannel: preferred
        )

        switch stream.state {
        case .playing:
            let live = stream.cells.compactMap { cell -> Int? in
                if case .playing = cell.state { return cell.channel }
                return nil
            }
            let failed = stream.cells.compactMap { cell -> Int? in
                if case .failed = cell.state { return cell.channel }
                return nil
            }
            if live.count > 1 {
                statusMessage = "Playing \(live.count) channels: \(live.map(String.init).joined(separator: ", "))."
            } else if let only = live.first {
                statusMessage = "Playing channel \(only)."
            } else {
                statusMessage = "Playing."
            }
            if !failed.isEmpty {
                statusMessage += " Failed: \(failed.map(String.init).joined(separator: ", ")) — use Restart on those tiles."
            }
        case .failed(let message):
            statusMessage = message
            if !settings.showLogs {
                settings.showLogs = true
            }
        default:
            break
        }
    }

    private func selectChannel(_ channel: Int) async {
        focusedChannel = channel
        guard stream.canSwitchChannel else { return }
        await stream.selectChannel(channel)
    }

    private func restartChannel(_ channel: Int) async {
        if !stream.canRestartChannels {
            statusMessage = "No live session — press Start first, then Restart failed tiles."
            return
        }
        statusMessage = "Restarting channel \(channel)…"
        await stream.restartChannel(channel)
        if let cell = stream.cells.first(where: { $0.channel == channel }) {
            switch cell.state {
            case .playing:
                statusMessage = "Channel \(channel) playing again."
            case .failed(let message):
                statusMessage = "Channel \(channel) restart failed: \(message)"
                if !settings.showLogs { settings.showLogs = true }
            default:
                statusMessage = "Channel \(channel) restart finished."
            }
        }
    }
}
