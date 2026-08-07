import Foundation
import Combine

@MainActor
final class StreamEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case probing(String)
        case starting
        case tunneling
        case playing(URL)
        case failed(String)
    }

    struct ChannelCell: Identifiable, Equatable {
        let channel: Int
        var state: State
        var activeRTSP: String

        var id: Int { channel }

        var playlistURL: URL? {
            if case .playing(let url) = state { return url }
            return nil
        }
    }

    private struct Pipeline {
        var ffmpegProcess: Process?
        var stderrTask: Task<Void, Never>?
        var hlsDirectory: URL?
        var hlsServer: LocalHLSServer?
    }

    /// Credentials / path info needed to restart a single channel.
    private struct LiveSession {
        let username: String
        let password: String
        var subtype: Int
        let channels: [Int]
        let usesTunnel: Bool
        var relayTag: String
        var ffmpeg: String
        /// Direct RTSP only.
        var hostIP: String = ""
        var rtspPort: Int = 554
    }

    private var channelRestartTask: Task<Void, Never>?

    @Published private(set) var state: State = .idle
    @Published private(set) var cells: [ChannelCell] = []
    @Published private(set) var activeRTSP: String = ""
    @Published private(set) var logLines: [String] = []
    @Published private(set) var liveChannel: Int?
    /// Tunnel or direct session is live enough to focus / restart a channel.
    var canSwitchChannel: Bool { session != nil }

    var canRestartChannels: Bool {
        guard let session else { return false }
        if session.usesTunnel { return tunnel.isRunning }
        return true
    }
    /// Default to relay — WAN RTSP is usually closed for InstOn/gCMOB devices.
    @Published var mode: StreamMode = .p2pRelay

    private var pipelines: [Int: Pipeline] = [:]
    private var session: LiveSession?
    private let tunnel = P2PTunnel(localPort: 1554)
    private let fileManager = FileManager.default

    var isBusy: Bool {
        switch state {
        case .starting, .probing, .tunneling:
            return true
        default:
            return cells.contains {
                switch $0.state {
                case .starting, .probing, .tunneling: return true
                default: return false
                }
            }
        }
    }

    var isPlaying: Bool {
        if case .playing = state { return true }
        return cells.contains {
            if case .playing = $0.state { return true }
            return false
        }
    }

    func stop() {
        channelRestartTask?.cancel()
        channelRestartTask = nil
        let keys = Array(pipelines.keys)
        for channel in keys {
            stopPipeline(channel: channel)
        }
        pipelines.removeAll()
        tunnel.stop()
        session = nil
        liveChannel = nil
        activeRTSP = ""
        cells = []
        state = .idle
    }

    /// Start live view for one or more channels simultaneously.
    /// P2P/relay: one shared tunnel, concurrent local RTSP clients (dh-p2p multi-realm).
    /// Direct RTSP: concurrent WAN/LAN clients.
    func start(
        device: DeviceLookupResult,
        username: String,
        password: String,
        channels: [Int],
        subtype: Int,
        preferredChannel: Int? = nil
    ) async {
        stop()
        let ordered = uniqueOrderedChannels(channels)
        guard !ordered.isEmpty else {
            state = .failed("Select at least one channel.")
            return
        }

        let primary = preferredChannel.flatMap { ordered.contains($0) ? $0 : nil } ?? ordered[0]
        liveChannel = primary

        state = .starting
        logLines.removeAll()
        cells = ordered.map { ChannelCell(channel: $0, state: .starting, activeRTSP: "") }

        guard let ffmpeg = Self.resolveFFmpegPath() else {
            state = .failed("ffmpeg not found. Expected Vendor/ffmpeg next to the package.")
            markAllFailed("ffmpeg not found")
            return
        }

        let prefersP2P = device.visit.lowercased().contains("p2p")
            || device.p2pType.lowercased().contains("p2p")
            || device.ipAddress.isEmpty

        let modes: [StreamMode]
        switch mode {
        case .auto:
            modes = prefersP2P
                ? [.p2pRelay, .p2p]
                : [.p2pRelay, .p2p, .directRTSP]
        default:
            modes = [mode]
        }

        appendLog(
            "Start serial=\(device.serial) channels=\(ordered.map(String.init).joined(separator: ",")) mode=\(mode.rawValue) → \(modes.map(\.rawValue).joined(separator: ", "))"
        )

        for attempt in modes {
            appendLog("—— Mode: \(attempt.rawValue) ——")
            switch attempt {
            case .directRTSP:
                if await tryDirectRTSP(
                    device: device,
                    username: username,
                    password: password,
                    channels: ordered,
                    subtype: subtype,
                    ffmpeg: ffmpeg
                ) {
                    return
                }
            case .p2p, .p2pRelay:
                if await tryP2P(
                    serial: device.serial,
                    relay: attempt == .p2pRelay,
                    username: username,
                    password: password,
                    channels: ordered,
                    subtype: subtype,
                    ffmpeg: ffmpeg
                ) {
                    return
                }
            case .auto:
                break
            }
        }

        let message = """
        Could not start live view.

        Tried: \(modes.map(\.rawValue).joined(separator: ", ")).
        Device reports visit=\(device.visit) / p2p=\(device.p2pType).

        Tips:
        • Close gCMOB (and any VLC) so nothing else holds the P2P session
        • Use Sub stream (Main often times out over relay / multiview)
        • Confirm RTSP device user/password (digest after 401)
        • Mode “P2P Relay” is preferred over direct P2P on WAN NAT
        """
        state = .failed(message)
        if !isPlaying {
            markAllFailed("Stream failed")
        }
    }

    func start(
        device: DeviceLookupResult,
        username: String,
        password: String,
        channel: Int,
        subtype: Int
    ) async {
        await start(
            device: device,
            username: username,
            password: password,
            channels: [channel],
            subtype: subtype,
            preferredChannel: channel
        )
    }

    /// Focus a tile (all channels keep streaming when simultaneous multiview is up).
    func selectChannel(_ channel: Int) async {
        guard session != nil else { return }
        liveChannel = channel
        if let cell = cells.first(where: { $0.channel == channel }),
           case .playing(let url) = cell.state {
            state = .playing(url)
            activeRTSP = cell.activeRTSP
            appendLog("Focused channel \(channel)")
        }
    }

    /// Restart a single failed (or stale) channel without tearing down others / the tunnel.
    func restartChannel(_ channel: Int) async {
        guard let session else {
            appendLog("Cannot restart channel \(channel) — start a session first")
            return
        }
        if session.usesTunnel && !tunnel.isRunning {
            updateCell(channel, state: .failed("P2P tunnel is down — press Start"), rtsp: "")
            return
        }

        // Serialize restarts so Bind handshakes do not pile up.
        channelRestartTask?.cancel()
        let task = Task { @MainActor in
            await self.performRestartChannel(channel)
        }
        channelRestartTask = task
        await task.value
    }

    private func performRestartChannel(_ channel: Int) async {
        guard let session else { return }
        if Task.isCancelled { return }

        appendLog("Restarting channel \(channel)…")
        stopPipeline(channel: channel)
        try? await Task.sleep(nanoseconds: 450_000_000)
        if Task.isCancelled { return }

        // Ensure cell exists even if this channel failed before cells were fully built.
        if cells.firstIndex(where: { $0.channel == channel }) == nil {
            cells.append(ChannelCell(channel: channel, state: .starting, activeRTSP: ""))
        }
        updateCell(channel, state: .starting, rtsp: "")

        var subtypeOrder = [session.subtype]
        let alternate = session.subtype == 0 ? 1 : 0
        if !subtypeOrder.contains(alternate) {
            subtypeOrder.append(alternate)
        }

        for sub in subtypeOrder {
            if Task.isCancelled { return }
            if session.usesTunnel && !tunnel.isRunning {
                updateCell(channel, state: .failed("P2P tunnel exited"), rtsp: "")
                return
            }

            do {
                let ok = await launchAndSettleChannel(
                    channel: channel,
                    username: session.username,
                    password: session.password,
                    subtype: sub,
                    ffmpeg: session.ffmpeg,
                    usesTunnel: session.usesTunnel,
                    hostIP: session.hostIP,
                    rtspPort: session.rtspPort,
                    tag: session.usesTunnel ? session.relayTag : nil
                )
                if ok {
                    if var sess = self.session {
                        if !sess.channels.contains(channel) {
                            sess = LiveSession(
                                username: sess.username,
                                password: sess.password,
                                subtype: sub,
                                channels: sess.channels + [channel],
                                usesTunnel: sess.usesTunnel,
                                relayTag: sess.relayTag,
                                ffmpeg: sess.ffmpeg,
                                hostIP: sess.hostIP,
                                rtspPort: sess.rtspPort
                            )
                        } else {
                            sess.subtype = sub
                        }
                        self.session = sess
                    }
                    syncAggregateState()
                    appendLog("Channel \(channel) restarted successfully")
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        updateCell(channel, state: .failed("Restart failed — try again"), rtsp: "")
        syncAggregateState()
    }

    /// Launch one channel and wait for its HLS playlist (leaves other pipelines alone).
    @discardableResult
    private func launchAndSettleChannel(
        channel: Int,
        username: String,
        password: String,
        subtype: Int,
        ffmpeg: String,
        usesTunnel: Bool,
        hostIP: String,
        rtspPort: Int,
        tag: String?
    ) async -> Bool {
        if usesTunnel {
            guard let url = StreamURLBuilder.localTunnelURL(
                port: tunnel.localPort,
                username: username,
                password: password,
                channel: channel,
                subtype: subtype
            ) else {
                updateCell(channel, state: .failed("Bad RTSP URL"), rtsp: "")
                return false
            }
            let redacted = redact(url)
            updateCell(channel, state: .probing(redacted), rtsp: redacted)
            appendLog("Restart HLS ch\(channel) \(redacted) (subtype=\(subtype))")
            do {
                let handle = try launchHLS(
                    channel: channel,
                    ffmpegPath: ffmpeg,
                    rtspURL: url,
                    subtype: subtype
                )
                return await settleLaunches(
                    [
                        PendingLaunch(
                            channel: channel,
                            redacted: redacted,
                            subtype: subtype,
                            playlistFile: handle.playlistFile,
                            dir: handle.dir,
                            server: handle.server,
                            process: handle.process
                        )
                    ],
                    requireTunnel: true,
                    tag: tag
                )
            } catch {
                appendLog("Restart launch ch\(channel) failed: \(error.localizedDescription)")
                stopPipeline(channel: channel)
                updateCell(channel, state: .failed(error.localizedDescription), rtsp: "")
                return false
            }
        }

        let candidates = StreamURLBuilder.candidates(
            ip: hostIP,
            rtspPort: rtspPort,
            username: username,
            password: password,
            channel: channel,
            subtype: subtype
        )
        for url in candidates {
            if Task.isCancelled { return false }
            let redacted = redact(url)
            updateCell(channel, state: .probing(redacted), rtsp: redacted)
            appendLog("Restart probing \(redacted)")
            guard await probeRTSP(ffmpeg: ffmpeg, url: url) else { continue }
            do {
                let handle = try launchHLS(
                    channel: channel,
                    ffmpegPath: ffmpeg,
                    rtspURL: url,
                    subtype: subtype
                )
                let ok = await settleLaunches(
                    [
                        PendingLaunch(
                            channel: channel,
                            redacted: redacted,
                            subtype: subtype,
                            playlistFile: handle.playlistFile,
                            dir: handle.dir,
                            server: handle.server,
                            process: handle.process
                        )
                    ],
                    requireTunnel: false,
                    tag: nil
                )
                if ok { return true }
            } catch {
                appendLog("Restart launch ch\(channel) failed: \(error.localizedDescription)")
                stopPipeline(channel: channel)
            }
        }
        return false
    }

    private func tryDirectRTSP(
        device: DeviceLookupResult,
        username: String,
        password: String,
        channels: [Int],
        subtype: Int,
        ffmpeg: String
    ) async -> Bool {
        let port = device.rtspPort
        let ip = device.ipAddress

        // Launch every channel's HLS pipeline, then wait for readiness (true parallel streaming).
        var launched: [PendingLaunch] = []

        for channel in channels {
            updateCell(channel, state: .probing("ch\(channel)"), rtsp: "")
            let candidates = StreamURLBuilder.candidates(
                ip: ip,
                rtspPort: port,
                username: username,
                password: password,
                channel: channel,
                subtype: subtype
            )
            var launchedThis = false
            for url in candidates {
                let redacted = redact(url)
                appendLog("Probing \(redacted)")
                if await probeRTSP(ffmpeg: ffmpeg, url: url) {
                    do {
                        let handle = try launchHLS(
                            channel: channel,
                            ffmpegPath: ffmpeg,
                            rtspURL: url,
                            subtype: subtype
                        )
                        launched.append(
                            PendingLaunch(
                                channel: channel,
                                redacted: redacted,
                                subtype: subtype,
                                playlistFile: handle.playlistFile,
                                dir: handle.dir,
                                server: handle.server,
                                process: handle.process
                            )
                        )
                        launchedThis = true
                        break
                    } catch {
                        appendLog("Launch HLS ch\(channel) failed: \(error.localizedDescription)")
                        stopPipeline(channel: channel)
                    }
                }
            }
            if !launchedThis {
                updateCell(channel, state: .failed("No RTSP path for channel \(channel)"), rtsp: "")
            }
        }

        let anyPlaying = await settleLaunches(launched, requireTunnel: false, tag: nil)

        if anyPlaying {
            session = LiveSession(
                username: username,
                password: password,
                subtype: subtype,
                channels: channels,
                usesTunnel: false,
                relayTag: "Direct RTSP",
                ffmpeg: ffmpeg,
                hostIP: ip,
                rtspPort: port
            )
            syncAggregateState()
            return true
        }
        return false
    }

    private func tryP2P(
        serial: String,
        relay: Bool,
        username: String,
        password: String,
        channels: [Int],
        subtype: Int,
        ffmpeg: String
    ) async -> Bool {
        state = .tunneling
        for channel in channels {
            updateCell(channel, state: .tunneling, rtsp: "")
        }
        tunnel.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }

        let clouds = ["instaon"]
        // Prefer the UI stream choice; fall back to the other if HLS fails.
        // (Main can hang DESCRIBE on some NVRs — fallback restarts the tunnel.)
        var subtypeOrder = [subtype]
        let alternate = subtype == 0 ? 1 : 0
        if !subtypeOrder.contains(alternate) {
            subtypeOrder.append(alternate)
        }
        if subtype == 0 {
            appendLog("Using Main stream (will fall back to Sub if Main fails over the tunnel)")
        } else {
            appendLog("Using Sub stream (will fall back to Main if Sub fails)")
        }

        if channels.count > 1 {
            appendLog(
                "P2P multiview: starting \(channels.count) concurrent RTSP clients on one tunnel (channels \(channels.map(String.init).joined(separator: ", ")))"
            )
        }

        let tag = relay ? "P2P relay" : "P2P"
        appendLog("Opening P2P tunnel (\(tag))…")

        for cloud in clouds {
            do {
                try await tunnel.start(
                    serial: serial,
                    relay: relay,
                    cloud: cloud
                )
            } catch {
                appendLog("Tunnel failed (\(cloud)): \(error.localizedDescription)")
                tunnel.stop()
                continue
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
            if !tunnel.isRunning {
                appendLog("Tunnel exited before stream start")
                continue
            }

            let relayTag = "\(tag)/\(cloud)"
            session = LiveSession(
                username: username,
                password: password,
                subtype: subtype,
                channels: channels,
                usesTunnel: true,
                relayTag: relayTag,
                ffmpeg: ffmpeg,
                hostIP: "",
                rtspPort: 554
            )

            var anyPlaying = false
            var remaining = channels

            for sub in subtypeOrder where !remaining.isEmpty {
                if !tunnel.isRunning {
                    appendLog("Tunnel exited mid-start — restarting…")
                    do {
                        try await tunnel.start(serial: serial, relay: relay, cloud: cloud)
                    } catch {
                        appendLog("Tunnel restart failed: \(error.localizedDescription)")
                        break
                    }
                }

                let port = tunnel.localPort
                // Launch all remaining channels so ffmpeg encoders run in parallel.
                // Bind→CONN is serialized inside dh-p2p; small stagger softens accept pressure.
                var launched: [PendingLaunch] = []

                for (index, channel) in remaining.enumerated() {
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    if !tunnel.isRunning { break }

                    guard let url = StreamURLBuilder.localTunnelURL(
                        port: port,
                        username: username,
                        password: password,
                        channel: channel,
                        subtype: sub
                    ) else {
                        updateCell(channel, state: .failed("Bad RTSP URL"), rtsp: "")
                        continue
                    }

                    let redacted = redact(url)
                    updateCell(channel, state: .probing(redacted), rtsp: redacted)
                    state = .probing(redacted)
                    appendLog(
                        "Launching HLS ch\(channel) \(redacted) (subtype=\(sub)\(sub == 1 ? " sub" : " main"))"
                    )

                    do {
                        let handle = try launchHLS(
                            channel: channel,
                            ffmpegPath: ffmpeg,
                            rtspURL: url,
                            subtype: sub
                        )
                        launched.append(
                            PendingLaunch(
                                channel: channel,
                                redacted: redacted,
                                subtype: sub,
                                playlistFile: handle.playlistFile,
                                dir: handle.dir,
                                server: handle.server,
                                process: handle.process
                            )
                        )
                    } catch {
                        appendLog("Launch HLS ch\(channel) failed: \(error.localizedDescription)")
                        stopPipeline(channel: channel)
                        updateCell(channel, state: .failed(error.localizedDescription), rtsp: "")
                    }
                }

                let readyCount = await settleLaunches(launched, requireTunnel: true, tag: relayTag)
                if readyCount {
                    anyPlaying = true
                    if var sess = session {
                        sess.subtype = sub
                        session = sess
                    }
                }

                // Retry only channels that are still not playing.
                remaining = remaining.filter { ch in
                    guard let cell = cells.first(where: { $0.channel == ch }) else { return true }
                    if case .playing = cell.state { return false }
                    return true
                }

                if !remaining.isEmpty && sub != subtypeOrder.last {
                    appendLog(
                        "Retrying channels \(remaining.map(String.init).joined(separator: ",")) with alternate stream…"
                    )
                    // Hung Main/Sub leaves the PTCP realm unusable — full tunnel restart.
                    stopAllPipelines()
                    tunnel.stop()
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    do {
                        try await tunnel.start(serial: serial, relay: relay, cloud: cloud)
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    } catch {
                        appendLog("Tunnel restart for fallback failed: \(error.localizedDescription)")
                        break
                    }
                }
            }

            if anyPlaying {
                syncAggregateState()
                return true
            }

            appendLog("Local RTSP through tunnel failed (\(cloud))")
            stopAllPipelines()
            tunnel.stop()
            session = nil
        }
        return false
    }

    private struct PendingLaunch {
        let channel: Int
        let redacted: String
        let subtype: Int
        let playlistFile: URL
        let dir: URL
        let server: LocalHLSServer
        let process: Process
    }

    /// Poll all launched pipelines together so they become ready in parallel.
    /// Returns true if at least one channel started playing.
    @discardableResult
    private func settleLaunches(
        _ launches: [PendingLaunch],
        requireTunnel: Bool,
        tag: String?
    ) async -> Bool {
        guard !launches.isEmpty else { return false }

        struct Track {
            let item: PendingLaunch
            var firstSegmentAt: Date?
            var done: Bool
        }

        var tracks = launches.map { Track(item: $0, firstSegmentAt: nil, done: false) }
        // Copy-remux usually settles in a few seconds; keep headroom for slow relay.
        let deadline = Date().addingTimeInterval(75)
        var anyPlaying = false

        while Date() < deadline, tracks.contains(where: { !$0.done }) {
            for i in tracks.indices where !tracks[i].done {
                let item = tracks[i].item
                let process = item.process

                if !process.isRunning {
                    stopPipeline(channel: item.channel)
                    updateCell(item.channel, state: .failed("ffmpeg exited before playlist was ready"), rtsp: "")
                    appendLog("HLS ch\(item.channel) failed: ffmpeg exited early")
                    tracks[i].done = true
                    continue
                }
                if requireTunnel && !tunnel.isRunning {
                    stopPipeline(channel: item.channel)
                    updateCell(item.channel, state: .failed("P2P tunnel exited"), rtsp: "")
                    tracks[i].done = true
                    continue
                }

                if Self.hlsPlaylistReady(at: item.playlistFile, directory: item.dir, minSegments: 1) {
                    if tracks[i].firstSegmentAt == nil {
                        tracks[i].firstSegmentAt = Date()
                    }
                    let segs = Self.extinfCount(at: item.playlistFile)
                    let waited = Date().timeIntervalSince(tracks[i].firstSegmentAt ?? Date())
                    if segs >= 2 || waited >= 3 {
                        let playlist = item.server.playlistHTTPURL
                        let label: String
                        if let tag {
                            label = "\(item.redacted) [\(tag)]"
                        } else {
                            label = item.redacted
                        }
                        updateCell(item.channel, state: .playing(playlist), rtsp: label)
                        appendLog(
                            "HLS ch\(item.channel) ready (\(segs) segments) → \(playlist.absoluteString)"
                        )
                        if liveChannel == nil || liveChannel == item.channel {
                            liveChannel = item.channel
                            activeRTSP = label
                            state = .playing(playlist)
                        }
                        anyPlaying = true
                        tracks[i].done = true
                    }
                }
            }
            if tracks.allSatisfy(\.done) { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        for track in tracks where !track.done {
            let ch = track.item.channel
            stopPipeline(channel: ch)
            updateCell(ch, state: .failed("Timed out waiting for HLS playlist"), rtsp: "")
            appendLog("HLS ch\(ch) failed: Timed out waiting for HLS playlist")
        }

        return anyPlaying
    }

    private struct HLSLaunch {
        let playlistFile: URL
        let dir: URL
        let server: LocalHLSServer
        let process: Process
    }

    /// Spawn ffmpeg + local HTTP playlist server without waiting for segments.
    private func launchHLS(
        channel: Int,
        ffmpegPath: String,
        rtspURL: URL,
        subtype: Int
    ) throws -> HLSLaunch {
        stopPipeline(channel: channel)

        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("CameraStreamer-ch\(channel)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let playlistFile = dir.appendingPathComponent("index.m3u8")
        let segmentPattern = dir.appendingPathComponent("seg%03d.ts").path

        let server = LocalHLSServer(directory: dir)
        try server.start()
        appendLog("Local HLS ch\(channel) http://127.0.0.1:\(server.port)/index.m3u8")

        // Remux H.264 from the tunnel (no re-encode). A 1MB probesize starves on
        // slow P2P relay — VLC plays the same URL while ffmpeg never starts HLS.
        let isMain = subtype == 0
        appendLog(
            "HLS remux ch\(channel): copy → mpegts (\(isMain ? "main" : "sub"), small probe)"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-hide_banner", "-loglevel", "warning",
            "-rtsp_transport", "tcp",
            "-rtsp_flags", "prefer_tcp",
            "-fflags", "+genpts+discardcorrupt+nobuffer",
            "-flags", "low_delay",
            "-use_wallclock_as_timestamps", "1",
            // Live P2P: start after a tiny probe, not 1MB of RTP.
            "-analyzeduration", "500000",
            "-probesize", "65536",
            "-max_delay", "500000",
            "-i", rtspURL.absoluteString,
            "-an",
            "-map", "0:v:0",
            "-c:v", "copy",
            "-f", "hls",
            "-hls_time", "2",
            "-hls_list_size", "6",
            "-hls_flags", "delete_segments+append_list+independent_segments+program_date_time",
            "-hls_segment_type", "mpegts",
            "-hls_segment_filename", segmentPattern,
            "-hls_allow_cache", "0",
            playlistFile.path
        ]

        let err = Pipe()
        process.standardOutput = Pipe()
        process.standardError = err
        try process.run()

        let stderrTask = Task.detached { [weak self] in
            let handle = err.fileHandleForReading
            while !Task.isCancelled {
                let data: Data = await withCheckedContinuation { cont in
                    DispatchQueue.global().async {
                        cont.resume(returning: handle.availableData)
                    }
                }
                if data.isEmpty { break }
                if let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !line.isEmpty {
                    let engine = self
                    let safe = Self.redactRTSPCredentials(line)
                    await MainActor.run { engine?.appendLog("[ch\(channel)] \(safe)") }
                }
            }
        }

        pipelines[channel] = Pipeline(
            ffmpegProcess: process,
            stderrTask: stderrTask,
            hlsDirectory: dir,
            hlsServer: server
        )

        return HLSLaunch(playlistFile: playlistFile, dir: dir, server: server, process: process)
    }

    private func uniqueOrderedChannels(_ channels: [Int]) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for ch in channels where (1...64).contains(ch) {
            if seen.insert(ch).inserted {
                result.append(ch)
            }
        }
        return result
    }

    private func updateCell(_ channel: Int, state: State, rtsp: String) {
        if let idx = cells.firstIndex(where: { $0.channel == channel }) {
            cells[idx].state = state
            if !rtsp.isEmpty {
                cells[idx].activeRTSP = rtsp
            } else if case .idle = state {
                cells[idx].activeRTSP = ""
            }
        } else {
            cells.append(ChannelCell(channel: channel, state: state, activeRTSP: rtsp))
        }
    }

    private func markAllFailed(_ message: String) {
        cells = cells.map {
            var c = $0
            if case .playing = c.state { return c }
            c.state = .failed(message)
            return c
        }
    }

    private func syncAggregateState() {
        let playing = cells.filter {
            if case .playing = $0.state { return true }
            return false
        }
        if let focused = liveChannel,
           let cell = cells.first(where: { $0.channel == focused }),
           case .playing(let url) = cell.state {
            state = .playing(url)
            activeRTSP = cell.activeRTSP
            return
        }
        if let first = playing.first, case .playing(let url) = first.state {
            state = .playing(url)
            liveChannel = first.channel
            activeRTSP = first.activeRTSP
        } else if let failed = cells.first(where: {
            if case .failed = $0.state { return true }
            return false
        }), case .failed(let msg) = failed.state, !isPlaying {
            state = .failed(msg)
        } else if cells.contains(where: {
            switch $0.state {
            case .starting, .probing, .tunneling: return true
            default: return false
            }
        }) {
            state = .starting
        } else {
            state = .idle
        }
    }

    private func stopAllPipelines() {
        let keys = Array(pipelines.keys)
        for channel in keys {
            stopPipeline(channel: channel)
        }
    }

    private func stopPipeline(channel: Int) {
        guard var pipeline = pipelines[channel] else { return }
        pipeline.stderrTask?.cancel()
        pipeline.stderrTask = nil
        pipeline.hlsServer?.stop()
        pipeline.hlsServer = nil
        if let process = pipeline.ffmpegProcess {
            pipeline.ffmpegProcess = nil
            if process.isRunning {
                process.terminate()
            }
        }
        if let dir = pipeline.hlsDirectory {
            try? fileManager.removeItem(at: dir)
        }
        pipeline.hlsDirectory = nil
        pipelines.removeValue(forKey: channel)
    }

    private func probeRTSP(ffmpeg: String, url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-hide_banner", "-loglevel", "error",
                "-rtsp_transport", "tcp",
                "-i", url.absoluteString,
                "-t", "2",
                "-f", "null", "-"
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
                return
            }

            let box = process
            DispatchQueue.global().async {
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    box.waitUntilExit()
                    group.leave()
                }
                let timedOut = group.wait(timeout: .now() + 12) == .timedOut
                if timedOut, box.isRunning {
                    box.terminate()
                    box.waitUntilExit()
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: box.terminationStatus == 0)
                }
            }
        }
    }

    nonisolated private static func extinfCount(at playlist: URL) -> Int {
        guard let text = try? String(contentsOf: playlist, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "#EXTINF").count - 1
    }

    nonisolated private static func hlsPlaylistReady(at playlist: URL, directory: URL, minSegments: Int) -> Bool {
        guard let text = try? String(contentsOf: playlist, encoding: .utf8),
              text.contains("#EXTM3U"),
              extinfCount(at: playlist) >= minSegments else {
            return false
        }
        var found = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasSuffix(".ts"), !name.hasPrefix("#") else { continue }
            let file = directory.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = attrs[.size] as? NSNumber,
                  size.intValue > 512 else {
                return false
            }
            found += 1
        }
        return found >= minSegments
    }

    private func appendLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 300 {
            logLines.removeFirst(logLines.count - 300)
        }
    }

    private func redact(_ url: URL) -> String {
        Self.redactRTSPCredentials(url.absoluteString)
    }

    nonisolated private static func redactRTSPCredentials(_ text: String) -> String {
        // ffmpeg stderr often echoes the full input URL including password.
        text.replacingOccurrences(
            of: #"rtsp://([^:@/]+):([^@/]+)@"#,
            with: "rtsp://$1:***@",
            options: .regularExpression
        )
    }

    nonisolated static func resolveFFmpegPath() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []

        if let env = ProcessInfo.processInfo.environment["CAMERA_STREAMER_FFMPEG"] {
            candidates.append(env)
        }
        if let bundled = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            candidates.append(bundled)
        }
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path {
            candidates.append(resourceURL)
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(packageRoot.appendingPathComponent("Vendor/ffmpeg").path)
        candidates.append(fm.currentDirectoryPath + "/Vendor/ffmpeg")
        candidates.append(fm.currentDirectoryPath + "/CameraStreamer/Vendor/ffmpeg")
        candidates.append(contentsOf: [
            "/usr/local/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ])

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
