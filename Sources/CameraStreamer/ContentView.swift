import SwiftUI

struct ContentView: View {
    @StateObject private var pool = StreamPool()
    @ObservedObject private var settings = AppSettings.shared

    @State private var deviceResults: [UUID: DeviceLookupResult] = [:]
    @State private var isLookingUp = false
    @State private var statusMessage =
        "Pick a camera profile (or build a Custom view), then Start. Credentials are saved in Settings."
    @State private var showSettings = false
    @State private var focusedSlot: Int?
    @State private var channelDrafts: [String] = []

    private let client = InstaOnClient()

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider().overlay(Theme.cardBorder)

            HSplitView {
                controlPanel
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)

                videoPanel
                    .frame(minWidth: 520)
            }
            .padding(12)

            if settings.showLogs {
                Divider().overlay(Theme.cardBorder)
                logPanel
                    .frame(minHeight: 140, idealHeight: 180, maxHeight: 260)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.windowBackground)
        .animation(.easeInOut(duration: 0.22), value: settings.showLogs)
        .onAppear {
            settings.ensureChannelSlots(count: settings.gridCapacity)
            settings.ensureCustomSlots(count: settings.gridCapacity)
            syncChannelDrafts()
        }
        .onChange(of: settings.gridCapacity) { capacity in
            settings.ensureChannelSlots(count: capacity)
            settings.ensureCustomSlots(count: capacity)
            syncChannelDrafts()
        }
        .onChange(of: settings.channels) { _ in
            syncChannelDrafts()
        }
        .onDisappear { pool.stopAll() }
        // onDisappear is not guaranteed on Cmd+Q — make sure ffmpeg/dh-p2p children
        // never outlive the app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            pool.stopAll()
        }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(Theme.titleFont(16, weight: .bold))
                    Spacer()
                    Button("Done") { showSettings = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
                Divider().overlay(Theme.cardBorder)
                SettingsView(settings: settings)
            }
            .frame(minWidth: 500, minHeight: 540)
        }
    }

    // MARK: - Toolbar

    private var liveStatus: (color: Color, text: String) {
        let allCells = pool.engines.values.flatMap(\.cells)
        let live = allCells.filter {
            if case .playing = $0.state { return true } else { return false }
        }.count
        if live > 0 { return (Theme.success, "Live · \(live) ch") }
        if pool.isBusy { return (Theme.warning, "Starting…") }
        return (Theme.neutral, "Idle")
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            AppMarkBadge()

            VStack(alignment: .leading, spacing: 1) {
                Text("CameraStreamer")
                    .font(Theme.titleFont(15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(toolbarSubtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            StatusPill(color: liveStatus.color, text: liveStatus.text)

            layoutPicker
                .frame(maxWidth: 200)

            HStack(spacing: 8) {
                ToolbarIconButton(
                    systemImage: settings.showLogs ? "doc.text.fill" : "doc.text",
                    help: "Show or hide diagnostic logs",
                    isActive: settings.showLogs
                ) {
                    settings.showLogs.toggle()
                }
                .accessibilityLabel(settings.showLogs ? "Hide logs" : "Show logs")

                ToolbarIconButton(systemImage: "gearshape", help: "Device profiles and saved defaults") {
                    showSettings = true
                }
                .accessibilityLabel("Open settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: $settings.gridCapacity) {
            Text("1×1").tag(1)
            Text("2×2").tag(4)
            Text("3×3").tag(9)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Multiview layout")
        .help("Number of camera tiles")
    }

    // MARK: - Control panel

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("View", selection: $settings.viewMode) {
                    ForEach(LiveViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Device: one camera, many channels. Custom: mix devices/channels.")
                .accessibilityLabel("Live view mode")

                if settings.viewMode == .device {
                    deviceSection
                    channelSection
                } else {
                    customSection
                }

                streamDefaultsSection

                actionButtons

                if let device = selectedDeviceResult {
                    lookupSection(device)
                }

                statusSection

                CardCaption(text: "Close gCMOB while streaming. Prefer Sub for multiview. Restart a tile from its corner icon.")
                    .padding(.horizontal, 2)
            }
            .padding(.trailing, 4)
        }
    }

    private var deviceSection: some View {
        SectionCard(title: "Device", systemImage: "video.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Camera", selection: $settings.selectedProfileID) {
                    ForEach(settings.profiles) { profile in
                        Text(profile.displayName).tag(profile.id as UUID?)
                    }
                }
                .accessibilityLabel("Selected camera profile")
                .help("Saved device profiles — edit credentials in Settings")

                if let profile = settings.selectedProfile {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.serial.isEmpty ? profile.displayName : profile.serial)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                        if settings.password(for: profile.id).isEmpty {
                            Label("No password saved — set it in Settings.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.warning)
                        }
                    }
                } else {
                    HStack {
                        Text("No camera profiles yet.")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Add Profile") {
                            _ = settings.addProfile()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var channelSection: some View {
        SectionCard(
            title: "Multiview",
            systemImage: "square.grid.2x2",
            trailing: {
                HStack(spacing: 6) {
                    Button("All") { settings.setAllSlotsEnabled(true) }
                        .controlSize(.mini)
                        .help("Enable all slots for playback")
                    Button("None") { settings.setAllSlotsEnabled(false) }
                        .controlSize(.mini)
                        .help("Disable all slots")
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                CardCaption(text: "Check Play for each slot included when you press Start.")

                HStack(spacing: 8) {
                    Text("All streams")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Picker("All streams", selection: Binding(
                        get: { settings.subtype },
                        set: { onAllStreamsChange($0) }
                    )) {
                        Text("Sub").tag(1)
                        Text("Main").tag(0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Apply stream quality to all slots")
                    .help("Sets Main/Sub for every slot")
                }

                channelEditors
            }
        }
    }

    private var customSection: some View {
        SectionCard(title: "Custom view", systemImage: "rectangle.grid.2x2") {
            VStack(alignment: .leading, spacing: 10) {
                CardCaption(text: "Each tile: pick a device and a channel. Start opens one tunnel per device.")

                VStack(spacing: 8) {
                    ForEach(0..<settings.gridCapacity, id: \.self) { index in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 14, alignment: .trailing)

                            Picker("Device", selection: customProfileBinding(index)) {
                                Text("—").tag(UUID?.none)
                                ForEach(settings.profiles) { profile in
                                    Text(profile.displayName).tag(profile.id as UUID?)
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Device for custom slot \(index + 1)")

                            TextField("CH", text: customChannelBinding(index))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 52)
                                .accessibilityLabel("Channel for custom slot \(index + 1)")

                            Picker("Stream for custom slot \(index + 1)", selection: Binding(
                                get: {
                                    let slots = settings.customSlots
                                    guard index < slots.count else { return settings.subtype }
                                    return slots[index].subtype
                                },
                                set: { onCustomSlotSubtypeChange(index, $0) }
                            )) {
                                Text("Sub").tag(1)
                                Text("Main").tag(0)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.mini)
                            .frame(maxWidth: 96)
                            .accessibilityLabel("Stream quality for custom slot \(index + 1)")
                        }
                    }
                }
            }
        }
    }

    private var streamDefaultsSection: some View {
        SectionCard(title: "Streaming", systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Mode", selection: $settings.streamMode) {
                    ForEach(StreamMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .accessibilityLabel("Connection mode")
                CardCaption(text: "Auto tries direct RTSP before the relay tunnel when possible.")
            }
        }
    }

    private var channelEditors: some View {
        let count = settings.gridCapacity
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
                spacing: 8
            ) {
                ForEach(0..<count, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Toggle(
                                "Play",
                                isOn: bindingForSlotEnabled(index)
                            )
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help("Include this channel when starting")
                            .accessibilityLabel("Play channel slot \(index + 1)")

                            Text("Slot \(index + 1)")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                        }

                        TextField(
                            "CH",
                            text: bindingForChannelDraft(index)
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Channel number for slot \(index + 1)")
                        .onSubmit { commitChannelDrafts() }

                        Picker("Stream for slot \(index + 1)", selection: Binding(
                            get: { settings.slotSubtype(at: index) },
                            set: { onSlotSubtypeChange(index, $0) }
                        )) {
                            Text("Sub").tag(1)
                            Text("Main").tag(0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.mini)
                        .accessibilityLabel("Stream quality for slot \(index + 1)")
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
        HStack(spacing: 10) {
            Button {
                commitChannelDrafts()
                Task { await lookup() }
            } label: {
                Group {
                    if isLookingUp {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Look Up", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isLookingUp || settings.viewMode != .device || selectedSerialTrimmed.isEmpty)
            .keyboardShortcut("l", modifiers: [.command])
            .help("Query InstaOn for device metadata")
            .accessibilityLabel("Look up device")

            Button {
                commitChannelDrafts()
                Task { await startStream() }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!canStart)
            .keyboardShortcut(.defaultAction)
            .help("Start multiview for configured channels")
            .accessibilityLabel("Start stream")

            Button {
                pool.stopAll()
                statusMessage = "Stopped."
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!pool.isBusy && !pool.isPlaying)
            .keyboardShortcut(".", modifiers: [.command])
            .help("Stop all streams and tunnels")
            .accessibilityLabel("Stop stream")
        }
        .controlSize(.large)
    }

    private func lookupSection(_ device: DeviceLookupResult) -> some View {
        SectionCard(title: "Lookup", systemImage: "antenna.radiowaves.left.and.right") {
            Text(device.summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Device lookup result")
        }
    }

    private var statusSection: some View {
        SectionCard(title: "Status", systemImage: "info.circle") {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(liveStatus.color)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel("Status")
                    .accessibilityValue(statusMessage)
            }
        }
    }

    // MARK: - Video

    private var videoPanel: some View {
        VStack(spacing: 8) {
            MultiviewGrid(
                cells: displayCells,
                capacity: settings.gridCapacity,
                focusedSlot: focusedSlot,
                onFocus: { index in
                    focusedSlot = index
                    Task { await selectSlot(index) }
                },
                onRestart: { index in
                    focusedSlot = index
                    Task { await restartSlot(index) }
                },
                badges: tileBadges
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
            )

            if !focusedActiveRTSP.isEmpty {
                Text(focusedActiveRTSP)
                    .font(.caption2.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Active RTSP URL")
            }
        }
        .padding(4)
        .accessibilityElement(children: .contain)
    }

    private func profileFor(_ id: UUID) -> DeviceProfile? {
        settings.profiles.first { $0.id == id }
    }

    /// Engine lookups route through the device SERIAL so two profiles pointing
    /// at the same physical device share one engine/tunnel.
    private func engineFor(_ profile: DeviceProfile) -> StreamEngine {
        pool.engine(forSerial: profile.serial, fallbackID: profile.id)
    }

    private func engineIfPresentFor(_ profile: DeviceProfile) -> StreamEngine? {
        pool.engineIfPresent(forSerial: profile.serial, fallbackID: profile.id)
    }

    /// Read-only slot → (profileID, channel) mapping (safe to call during body).
    private func slotMapping(_ index: Int) -> (profileID: UUID, channel: Int)? {
        switch settings.viewMode {
        case .device:
            guard let profile = settings.selectedProfile else { return nil }
            let channels = settings.gridChannels
            guard index < channels.count else { return nil }
            return (profile.id, channels[index])
        case .custom:
            let slots = Array(settings.customSlots.prefix(settings.gridCapacity))
            guard index < slots.count, let pid = slots[index].profileID else { return nil }
            return (pid, slots[index].channel)
        }
    }

    /// Grid slots: live engine cells where streaming, placeholders otherwise.
    private var displayCells: [StreamEngine.ChannelCell] {
        switch settings.viewMode {
        case .device:
            let grid = settings.gridChannels
            let enabled = Array(settings.channelEnabled.prefix(settings.gridCapacity))
            let engineCells = settings.selectedProfile.flatMap { engineIfPresentFor($0)?.cells } ?? []
            return grid.enumerated().map { index, channel in
                let isOn = index < enabled.count ? enabled[index] : true
                if !isOn {
                    return StreamEngine.ChannelCell(channel: channel, state: .off, activeRTSP: "")
                }
                if let live = engineCells.first(where: { $0.channel == channel }) {
                    return live
                }
                return StreamEngine.ChannelCell(channel: channel, state: .idle, activeRTSP: "")
            }
        case .custom:
            let slots = Array(settings.customSlots.prefix(settings.gridCapacity))
            return slots.enumerated().map { _, slot in
                guard let pid = slot.profileID,
                      let profile = profileFor(pid) else {
                    return StreamEngine.ChannelCell(channel: slot.channel, state: .off, activeRTSP: "")
                }
                if let live = engineIfPresentFor(profile)?.cells.first(where: { $0.channel == slot.channel }) {
                    return live
                }
                return StreamEngine.ChannelCell(channel: slot.channel, state: .idle, activeRTSP: "")
            }
        }
    }

    private var tileBadges: [String]? {
        guard settings.viewMode == .custom else { return nil }
        let slots = Array(settings.customSlots.prefix(settings.gridCapacity))
        return slots.map { slot in
            guard let pid = slot.profileID,
                  let profile = settings.profiles.first(where: { $0.id == pid }) else {
                return "Empty slot"
            }
            return "\(profile.displayName) · CH \(slot.channel)"
        }
    }

    private var focusedActiveRTSP: String {
        guard let index = focusedSlot, let mapping = slotMapping(index),
              let profile = profileFor(mapping.profileID) else { return "" }
        return engineIfPresentFor(profile)?.activeRTSP ?? ""
    }

    // MARK: - Logs

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Logs")
                    .font(Theme.titleFont())
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                ToolbarIconButton(systemImage: "chevron.down", help: "Hide logs") {
                    settings.showLogs = false
                }
                .accessibilityLabel("Hide logs")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            LogTextView(text: statusText)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .accessibilityLabel("Diagnostic log output")
                .accessibilityValue(statusText)
        }
        .background(.bar)
    }

    // MARK: - Bindings / profile helpers

    private func customProfileBinding(_ index: Int) -> Binding<UUID?> {
        Binding(
            get: {
                let slots = settings.customSlots
                guard index < slots.count else { return nil }
                return slots[index].profileID
            },
            set: { settings.setCustomSlot(index: index, profileID: $0) }
        )
    }

    private func customChannelBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                let slots = settings.customSlots
                guard index < slots.count else { return "" }
                return String(slots[index].channel)
            },
            set: { raw in
                if let value = Int(raw.filter(\.isNumber)) {
                    settings.setCustomSlot(index: index, channel: value)
                }
            }
        )
    }

    // MARK: - Helpers

    private var selectedSerialTrimmed: String {
        settings.selectedProfile?.serial.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var selectedDeviceResult: DeviceLookupResult? {
        guard let id = settings.selectedProfileID else { return nil }
        return deviceResults[id]
    }

    private var canStart: Bool {
        guard !pool.isBusy else { return false }
        switch settings.viewMode {
        case .device:
            guard let profile = settings.selectedProfile else { return false }
            return !settings.password(for: profile.id).isEmpty
                && !selectedSerialTrimmed.isEmpty
                && !settings.channelsToPlay.isEmpty
        case .custom:
            let slots = settings.validCustomSlots
            guard !slots.isEmpty else { return false }
            return slots.allSatisfy { slot in
                slot.profileID.map { !settings.password(for: $0).isEmpty } ?? false
            }
        }
    }

    private var toolbarSubtitle: String {
        switch settings.viewMode {
        case .device:
            guard let profile = settings.selectedProfile else { return "Add a camera profile to stream" }
            let ch = settings.channelsToPlay.map(String.init).joined(separator: ", ")
            let label = ch.isEmpty ? "none" : ch
            return "\(profile.displayName)  ·  Play CH \(label)  ·  \(settings.streamMode.rawValue)"
        case .custom:
            return "Custom view  ·  \(settings.validCustomSlots.count) configured slot(s)  ·  \(settings.streamMode.rawValue)"
        }
    }

    private var statusText: String {
        var lines = [statusMessage]
        let logs = pool.mergedLogLines
        if !logs.isEmpty {
            lines.append("")
            lines.append(contentsOf: logs.suffix(80))
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

    private func lookupTarget(for profile: DeviceProfile) -> DeviceLookupResult {
        deviceResults[profile.id] ?? DeviceLookupResult(
            serial: profile.serial.trimmingCharacters(in: .whitespacesAndNewlines),
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
    }

    private func lookup() async {
        guard let profile = settings.selectedProfile else { return }
        isLookingUp = true
        statusMessage = "Querying InstaOn…"
        defer { isLookingUp = false }
        do {
            let result = try await client.lookupDevice(serial: selectedSerialTrimmed)
            deviceResults[profile.id] = result
            statusMessage = "Lookup OK — \(result.ipAddress) (RTSP \(result.rtspPort), P2P \(result.p2pPort))"
        } catch {
            deviceResults[profile.id] = nil
            statusMessage = error.localizedDescription
            if !settings.showLogs {
                settings.showLogs = true
            }
        }
    }

    private func startStream() async {
        commitChannelDrafts()
        switch settings.viewMode {
        case .device:
            await startSingleDevice()
        case .custom:
            await startCustomView()
        }
    }

    private func startSingleDevice() async {
        guard let profile = settings.selectedProfile else { return }
        let channels = settings.channelsToPlay
        guard !channels.isEmpty else {
            statusMessage = "Check Play for at least one channel slot."
            return
        }

        let engine = engineFor(profile)
        engine.mode = settings.streamMode

        // Per-slot Main/Sub overrides (grid position → slot subtype).
        var channelSubtypes: [Int: Int] = [:]
        let grid = settings.gridChannels
        for channel in channels {
            if let index = grid.firstIndex(of: channel) {
                channelSubtypes[channel] = settings.slotSubtype(at: index)
            }
        }

        let preferred: Int? = focusedSlot.flatMap { index in
            slotMapping(index).map { $0.channel }
        }.flatMap { channels.contains($0) ? $0 : nil } ?? channels.first
        statusMessage = "Starting \(settings.streamMode.rawValue) for \(channels.count) channel(s)…"

        let statusTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                switch engine.state {
                case .tunneling:
                    statusMessage = "Opening P2P tunnel…"
                case .probing(let url):
                    statusMessage = "Connecting stream… \(url)"
                case .starting:
                    statusMessage = "Starting \(settings.streamMode.rawValue) for \(channels.count) channel(s)…"
                case .playing, .failed, .idle, .off:
                    return
                }
            }
        }

        await engine.start(
            device: lookupTarget(for: profile),
            username: profile.username,
            password: settings.password(for: profile.id),
            channels: channels,
            subtype: settings.subtype,
            channelSubtypes: channelSubtypes,
            preferredChannel: preferred
        )
        statusTask.cancel()
        updateStatusAfterStart()
    }

    private func startCustomView() async {
        let slots = settings.validCustomSlots
        guard !slots.isEmpty else {
            statusMessage = "Configure at least one custom slot (device + channel)."
            return
        }

        // Group slots per *physical device* (by serial): one engine/tunnel each.
        // Two profiles with the same serial share one tunnel — a device allows
        // only one P2P session.
        var groups: [String: (profile: DeviceProfile, slots: [CustomSlot])] = [:]
        for slot in slots {
            guard let pid = slot.profileID, let profile = profileFor(pid) else { continue }
            let key = StreamPool.serialKey(profile.serial, fallbackID: profile.id)
            if groups[key] == nil {
                groups[key] = (profile, [])
            }
            groups[key]!.slots.append(slot)
        }

        statusMessage = "Starting \(slots.count) channel(s) across \(groups.count) device(s)…"

        // Start devices SEQUENTIALLY: the InstaOn cloud (and each device's
        // single-session P2P channel) does not tolerate overlapping handshakes
        // from the same client — concurrent starts made all tunnels time out.
        // Channels still stream concurrently once every tunnel is up.
        // Watch stopEpoch so the Stop button cancels pending device starts/retries.
        let startEpoch = pool.stopEpoch
        let ordered = groups.sorted(by: { $0.key < $1.key })
        for (index, (_, group)) in ordered.enumerated() {
            if pool.stopEpoch != startEpoch {
                statusMessage = "Stopped."
                return
            }
            let engine = engineFor(group.profile)
            engine.mode = settings.streamMode
            let target = lookupTarget(for: group.profile)
            let password = settings.password(for: group.profile.id)
            statusMessage =
                "Starting device \(index + 1)/\(ordered.count) (\(group.profile.displayName))…"

            // One retry: relay handshakes are flaky by nature.
            for attempt in 0...1 {
                if pool.stopEpoch != startEpoch {
                    statusMessage = "Stopped."
                    return
                }
                await engine.start(
                    device: target,
                    username: group.profile.username,
                    password: password,
                    channels: group.slots.map(\.channel),
                    subtype: settings.subtype,
                    channelSubtypes: Dictionary(
                        group.slots.map { ($0.channel, $0.subtype) },
                        uniquingKeysWith: { _, last in last }
                    ),
                    preferredChannel: group.slots.first?.channel
                )
                if engine.isPlaying { break }
                if attempt == 0 {
                    statusMessage = "Retrying device \(group.profile.displayName)…"
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            // Let the cloud breathe before the next device's handshake.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        updateStatusAfterStart()
    }

    private func updateStatusAfterStart() {
        let allCells = pool.engines.values.flatMap(\.cells)
        let live = allCells.filter { if case .playing = $0.state { return true } else { return false } }
        let failed = allCells.filter { if case .failed = $0.state { return true } else { return false } }

        if !live.isEmpty {
            statusMessage = "Playing \(live.count) channel(s)."
            if !failed.isEmpty {
                statusMessage += " \(failed.count) failed — use Restart on those tiles."
            }
        } else if let firstFailed = failed.first, case .failed(let msg) = firstFailed.state {
            statusMessage = msg
            if !settings.showLogs {
                settings.showLogs = true
            }
        }
    }

    private func selectSlot(_ index: Int) async {
        guard let mapping = slotMapping(index),
              let profile = profileFor(mapping.profileID),
              let engine = engineIfPresentFor(profile),
              engine.canSwitchChannel else { return }
        await engine.selectChannel(mapping.channel)
    }

    // MARK: - Stream (Main/Sub) change → live restart

    /// Restart the slot's channel with the newly chosen stream, if a session is live.
    private func restartSlotWithSubtype(_ index: Int, _ value: Int) {
        guard let mapping = slotMapping(index),
              let profile = profileFor(mapping.profileID),
              let engine = engineIfPresentFor(profile),
              engine.canRestartChannels else { return }
        if settings.viewMode == .device && !settings.isSlotEnabled(index) { return }
        let label = value == 0 ? "Main" : "Sub"
        statusMessage = "Switching channel \(mapping.channel) to \(label)…"
        Task { @MainActor in
            await engine.restartChannel(mapping.channel, subtype: value)
            if let cell = engine.cells.first(where: { $0.channel == mapping.channel }),
               case .playing = cell.state {
                statusMessage = "Channel \(mapping.channel) now playing \(label)."
            } else {
                statusMessage = "Channel \(mapping.channel) \(label) restart did not settle — use the tile restart button."
            }
        }
    }

    private func onSlotSubtypeChange(_ index: Int, _ value: Int) {
        settings.setSlotSubtype(at: index, to: value)
        restartSlotWithSubtype(index, value)
    }

    private func onCustomSlotSubtypeChange(_ index: Int, _ value: Int) {
        settings.setCustomSlot(index: index, subtype: value)
        restartSlotWithSubtype(index, value)
    }

    private func onAllStreamsChange(_ value: Int) {
        settings.setAllSlotSubtypes(value)
        // Restart every live channel of the selected device with the new stream.
        guard let profile = settings.selectedProfile,
              let engine = engineIfPresentFor(profile),
              engine.canRestartChannels else { return }
        let channels = engine.cells.map(\.channel)
        guard !channels.isEmpty else { return }
        let label = value == 0 ? "Main" : "Sub"
        statusMessage = "Restarting \(channels.count) channel(s) with \(label)…"
        Task { @MainActor in
            var ok = 0
            for channel in channels {
                await engine.restartChannel(channel, subtype: value)
                if let cell = engine.cells.first(where: { $0.channel == channel }),
                   case .playing = cell.state {
                    ok += 1
                }
            }
            statusMessage = "Playing \(ok)/\(channels.count) channel(s) with \(label)."
        }
    }

    private func restartSlot(_ index: Int) async {
        guard let mapping = slotMapping(index),
              let profile = profileFor(mapping.profileID),
              let engine = engineIfPresentFor(profile) else { return }
        guard engine.canRestartChannels else {
            statusMessage = "No live session — press Start first, then Restart failed tiles."
            return
        }
        statusMessage = "Restarting channel \(mapping.channel)…"
        await engine.restartChannel(mapping.channel)
        if let cell = engine.cells.first(where: { $0.channel == mapping.channel }) {
            switch cell.state {
            case .playing:
                statusMessage = "Channel \(mapping.channel) playing again."
            case .failed(let message):
                statusMessage = "Channel \(mapping.channel) restart failed: \(message)"
                if !settings.showLogs { settings.showLogs = true }
            default:
                statusMessage = "Channel \(mapping.channel) restart finished."
            }
        }
    }
}
