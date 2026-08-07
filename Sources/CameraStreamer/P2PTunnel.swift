import Foundation

enum StreamMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case p2p = "P2P"
    case p2pRelay = "P2P Relay"
    case directRTSP = "Direct RTSP"

    var id: String { rawValue }
}

/// Drains child-process pipes off the main thread.
/// `FileHandle.availableData` blocks until bytes arrive — never call it on MainActor.
private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var handles: [FileHandle] = []

    func start(pipes: [Pipe]) {
        for pipe in pipes {
            let handle = pipe.fileHandleForReading
            handles.append(handle)
            handle.readabilityHandler = { [weak self] h in
                let data = h.availableData
                guard !data.isEmpty else {
                    h.readabilityHandler = nil
                    return
                }
                self?.lock.lock()
                self?.buffer.append(data)
                self?.lock.unlock()
            }
        }
    }

    func stop() {
        for handle in handles {
            handle.readabilityHandler = nil
        }
        handles.removeAll()
    }

    func takeString() -> String {
        lock.lock()
        let data = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@MainActor
final class P2PTunnel {
    private(set) var process: Process?
    private var drain: PipeDrain?
    private var outputTask: Task<Void, Never>?
    private(set) var localPort: Int
    private let preferredPort: Int
    var onLog: ((String) -> Void)?

    init(localPort: Int = 1554) {
        self.preferredPort = localPort
        self.localPort = localPort
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func stop() {
        outputTask?.cancel()
        outputTask = nil
        drain?.stop()
        drain = nil
        guard let process else { return }
        self.process = nil
        if process.isRunning {
            process.terminate()
        }
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if process.isRunning {
                process.interrupt()
            }
        }
    }

    func start(
        serial: String,
        relay: Bool,
        cloud: String = "instaon"
    ) async throws {
        stop()
        try? await Task.sleep(nanoseconds: 250_000_000)

        guard let binary = Self.resolveBinaryPath() else {
            throw NSError(
                domain: "CameraStreamer",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "dh-p2p binary not found in Vendor/"]
            )
        }

        localPort = await Self.firstFreePort(startingAt: preferredPort)
        if localPort != preferredPort {
            onLog?("Port \(preferredPort) busy — using 127.0.0.1:\(localPort)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // Match the verified CLI: --relay -c instaon -t 0 -p 127.0.0.1:PORT:554 -s SN
        // Do not pass -u/--password: channel auth (-t 1) is unused, and device
        // RTSP digest is applied by ffmpeg on the local URL, not by dh-p2p.
        var args: [String] = []
        if relay {
            args.append("--relay")
        }
        args.append(contentsOf: [
            "-c", cloud,
            "-t", "0",
            "-p", "127.0.0.1:\(localPort):554",
            "-s", serial,
        ])
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let timeout: TimeInterval = cloud == "instaon_ctc" ? 18 : 40

        onLog?("Starting dh-p2p cloud=\(cloud)\(relay ? " relay" : "") port=\(localPort)")
        onLog?("Tip: close gCMOB live view before connecting (phone holds /p2p-channel).")
        onLog?("Args: \(args.joined(separator: " "))")

        let drain = PipeDrain()
        drain.start(pipes: [stdout, stderr])
        self.drain = drain

        try process.run()
        self.process = process

        let (ready, lastLogs) = await waitForReady(drain: drain, process: process, timeout: timeout)
        guard ready else {
            let code = process.isRunning ? -1 : Int(process.terminationStatus)
            stop()
            var detail = "P2P tunnel not ready on cloud \(cloud) (exit \(code))."
            let lower = lastLogs.lowercased()
            if lower.contains("p2p-channel timed out")
                || lower.contains("stuck on 100")
                || lower.contains("waiting for p2p-channel")
                || lower.contains("ptcp sync response missing")
                || lower.contains("invalid ptcp magic") {
                detail +=
                    " Device did not complete P2P/PTCP — close live view in gCMOB, wait ~10s, retry. Avoid a second manual tunnel on the same SN."
            } else if lower.contains("404 p2p-channel") {
                detail += " Device not registered on P2P cloud — open live view once in gCMOB, then retry here."
            } else if lower.contains("403 p2p-channel") {
                detail += " Channel auth rejected."
            }
            throw NSError(
                domain: "CameraStreamer",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }

        // Keep draining so the child never blocks on a full stdout pipe.
        outputTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.process?.isRunning == true {
                let chunk = drain.takeString()
                if !chunk.isEmpty {
                    self.forwardInterestingLogs(chunk)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        onLog?("P2P tunnel ready on 127.0.0.1:\(localPort) (\(cloud))")
    }

    private func waitForReady(
        drain: PipeDrain,
        process: Process,
        timeout: TimeInterval
    ) async -> (Bool, String) {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = ""
        var lastProgressAt = Date()

        while Date() < deadline {
            if !process.isRunning {
                let leftover = drain.takeString()
                if !leftover.isEmpty {
                    forwardInterestingLogs(leftover)
                    buffer += leftover
                }
                onLog?("dh-p2p exited early (code \(process.terminationStatus))")
                return (false, buffer)
            }

            let chunk = drain.takeString()
            if !chunk.isEmpty {
                buffer += chunk
                forwardInterestingLogs(chunk)
                lastProgressAt = Date()
            } else if Date().timeIntervalSince(lastProgressAt) > 8 {
                // Heartbeat so the UI does not look frozen on silent socket waits.
                onLog?("…still connecting (waiting on P2P cloud / device)")
                lastProgressAt = Date()
            }

            let lower = buffer.lowercased()
            if lower.contains("address already in use") {
                onLog?("Bind failed on \(localPort) (still busy)")
                return (false, buffer)
            }
            if lower.contains("p2p tunnel failed")
                || lower.contains("p2p-channel timed out")
                || lower.contains("handshake failed") {
                return (false, buffer)
            }
            if lower.contains("camera_streamer_tunnel_ready")
                || (lower.contains("ready to connect") && lower.contains("ptcp session established")) {
                return (true, buffer)
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        onLog?("Timed out waiting for CAMERA_STREAMER_TUNNEL_READY (\(Int(timeout))s)")
        return (false, buffer)
    }

    /// Avoid flooding the UI with full PTCP/hex dumps (that alone can freeze SwiftUI).
    private func forwardInterestingLogs(_ chunk: String) {
        for line in chunk.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard !text.isEmpty else { continue }
            let lower = text.lowercased()
            let interesting =
                lower.contains("using cloud")
                || lower.contains("using relay")
                || lower.contains("using direct")
                || lower.contains("falling back")
                || lower.contains("hole-punch")
                || lower.contains("ptcp session")
                || lower.contains("ptcp bind")
                || lower.contains("ptcp conn")
                || lower.contains("ptcp status")
                || lower.contains("ready to connect")
                || lower.contains("camera_streamer")
                || lower.contains("attempting")
                || lower.contains("failed")
                || lower.contains("error")
                || lower.contains("timeout")
                || lower.contains("timed out")
                || lower.contains("waiting for p2p")
                || lower.contains("p2p-channel")
                || lower.contains("relay agent")
                || lower.contains("close gcmob")
                || lower.contains("accepted connection")
                || lower.contains("bind failed")
                || lower.contains("address already")
                || lower.contains("multiview")
                || lower.contains("concurrent rtsp")
                || lower.hasPrefix("rtsp url")
                || lower.contains("device info")
                || lower.contains("401")
                || lower.contains("unauthorized")
                || lower.contains("payload #")
                || lower.contains("reader:")
                || lower.contains("writer:")
                || lower.contains("probe/device")
            if interesting {
                onLog?(text)
            }
        }
    }

    nonisolated private static func firstFreePort(startingAt start: Int) async -> Int {
        await Task.detached(priority: .userInitiated) {
            for port in start..<(start + 30) {
                let sock = socket(AF_INET, SOCK_STREAM, 0)
                guard sock >= 0 else { continue }
                defer { close(sock) }
                var yes: Int32 = 1
                setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(UInt16(port).bigEndian)
                addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                let bindResult = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if bindResult == 0 {
                    return port
                }
            }
            return start
        }.value
    }

    nonisolated static func resolveBinaryPath() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []

        if let env = ProcessInfo.processInfo.environment["CAMERA_STREAMER_DHP2P"] {
            candidates.append(env)
        }
        if let bundled = Bundle.main.path(forResource: "dh-p2p-bin", ofType: nil) {
            candidates.append(bundled)
        }
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("dh-p2p-bin").path {
            candidates.append(resourceURL)
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(packageRoot.appendingPathComponent("Vendor/dh-p2p-bin").path)
        candidates.append(packageRoot.appendingPathComponent("Vendor/dh-p2p/target/release/dh-p2p").path)
        candidates.append(fm.currentDirectoryPath + "/Vendor/dh-p2p-bin")
        candidates.append(fm.currentDirectoryPath + "/CameraStreamer/Vendor/dh-p2p-bin")

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
