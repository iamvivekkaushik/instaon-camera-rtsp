import Combine
import Foundation

/// Owns one StreamEngine per *physical device* (keyed by serial, not profile id):
/// several profiles can point at the same device, and a device allows only ONE
/// P2P session — two tunnels to one serial kill each other.
@MainActor
final class StreamPool: ObservableObject {
    @Published private(set) var engines: [String: StreamEngine] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    private var nextTunnelPort = 1554

    /// Normalized identity of a device for engine sharing.
    static func serialKey(_ serial: String, fallbackID: UUID? = nil) -> String {
        let sn = serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !sn.isEmpty { return sn }
        // No serial: treat as a distinct (non-mergeable) device.
        return "profile-\(fallbackID?.uuidString ?? UUID().uuidString)"
    }

    func engine(forSerial serial: String, fallbackID: UUID? = nil) -> StreamEngine {
        let key = Self.serialKey(serial, fallbackID: fallbackID)
        if let engine = engines[key] { return engine }
        let engine = StreamEngine(tunnelPort: nextTunnelPort)
        nextTunnelPort += 1
        engines[key] = engine
        // Forward engine updates so views holding the pool re-render when
        // any device's cells/state/logs change.
        subscriptions[key] = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return engine
    }

    /// Read-only lookup (safe during view body evaluation).
    func engineIfPresent(forSerial serial: String, fallbackID: UUID? = nil) -> StreamEngine? {
        engines[Self.serialKey(serial, fallbackID: fallbackID)]
    }

    var isBusy: Bool { engines.values.contains { $0.isBusy } }
    var isPlaying: Bool { engines.values.contains { $0.isPlaying } }

    /// Log lines are ISO8601-stamped, so plain string sort = chronological order.
    var mergedLogLines: [String] {
        Array(engines.values.flatMap(\.logLines).sorted().suffix(300))
    }

    func stopAll() {
        for engine in engines.values {
            engine.stop()
        }
    }
}
