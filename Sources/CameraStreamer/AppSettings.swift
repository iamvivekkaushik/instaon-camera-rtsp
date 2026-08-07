import Foundation
import SwiftUI
import Combine

/// Persisted app preferences (device credentials, multiview layout, log panel).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let serial = "cs.serial"
        static let username = "cs.username"
        static let password = "cs.password"
        static let channelsCSV = "cs.channelsCSV"
        static let channelEnabledCSV = "cs.channelEnabledCSV"
        static let subtype = "cs.subtype"
        static let streamMode = "cs.streamMode"
        static let gridCapacity = "cs.gridCapacity"
        static let showLogs = "cs.showLogs"
        static let hasLaunched = "cs.hasLaunched"
    }

    @Published var serial: String {
        didSet { defaults.set(serial, forKey: Key.serial) }
    }
    @Published var username: String {
        didSet { defaults.set(username, forKey: Key.username) }
    }
    @Published var password: String {
        didSet { defaults.set(password, forKey: Key.password) }
    }
    /// Ordered channel list for multiview slots.
    @Published var channels: [Int] {
        didSet {
            defaults.set(channels.map(String.init).joined(separator: ","), forKey: Key.channelsCSV)
        }
    }
    /// Per-slot: include in Start playback.
    @Published var channelEnabled: [Bool] {
        didSet {
            defaults.set(
                channelEnabled.map { $0 ? "1" : "0" }.joined(separator: ","),
                forKey: Key.channelEnabledCSV
            )
        }
    }
    /// 0 = main, 1 = sub.
    @Published var subtype: Int {
        didSet { defaults.set(subtype, forKey: Key.subtype) }
    }
    @Published var streamMode: StreamMode {
        didSet { defaults.set(streamMode.rawValue, forKey: Key.streamMode) }
    }
    /// Preferred grid size: 1, 4, or 9 cells.
    @Published var gridCapacity: Int {
        didSet { defaults.set(gridCapacity, forKey: Key.gridCapacity) }
    }
    @Published var showLogs: Bool {
        didSet { defaults.set(showLogs, forKey: Key.showLogs) }
    }

    private init() {
        let firstLaunch = !defaults.bool(forKey: Key.hasLaunched)
        defaults.set(true, forKey: Key.hasLaunched)

        serial = defaults.string(forKey: Key.serial) ?? (firstLaunch ? "2009011801001104" : "")
        username = defaults.string(forKey: Key.username) ?? "admin"
        password = defaults.string(forKey: Key.password) ?? ""
        subtype = defaults.object(forKey: Key.subtype) as? Int ?? 1
        showLogs = defaults.object(forKey: Key.showLogs) as? Bool ?? false

        let modeRaw = defaults.string(forKey: Key.streamMode) ?? StreamMode.p2pRelay.rawValue
        streamMode = StreamMode(rawValue: modeRaw) ?? .p2pRelay

        let cap = defaults.object(forKey: Key.gridCapacity) as? Int ?? 4
        gridCapacity = [1, 4, 9].contains(cap) ? cap : 4

        let parsedChannels: [Int]
        if let csv = defaults.string(forKey: Key.channelsCSV), !csv.isEmpty {
            let parsed = csv
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { (1...64).contains($0) }
            parsedChannels = parsed.isEmpty ? [1, 2, 3, 4] : parsed
        } else {
            parsedChannels = [1, 2, 3, 4]
        }

        let parsedEnabled: [Bool]
        if let csv = defaults.string(forKey: Key.channelEnabledCSV), !csv.isEmpty {
            parsedEnabled = csv
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) != "0" }
        } else {
            parsedEnabled = Array(repeating: true, count: max(parsedChannels.count, cap))
        }

        // Normalize to gridCapacity, then assign stored properties.
        var ch = parsedChannels
        while ch.count < cap { ch.append(min((ch.max() ?? 0) + 1, 64)) }
        if ch.count > cap { ch = Array(ch.prefix(cap)) }

        var en = parsedEnabled
        while en.count < cap { en.append(true) }
        if en.count > cap { en = Array(en.prefix(cap)) }

        channels = ch
        channelEnabled = en
    }

    /// Channel numbers shown in the grid (all slots).
    var gridChannels: [Int] {
        Array(channels.prefix(gridCapacity))
    }

    /// Channel numbers with Play checked — used when starting playback.
    var channelsToPlay: [Int] {
        let ch = gridChannels
        let en = Array(channelEnabled.prefix(gridCapacity))
        var out: [Int] = []
        var seen = Set<Int>()
        for i in ch.indices {
            let enabled = i < en.count ? en[i] : true
            guard enabled else { continue }
            let n = ch[i]
            if seen.insert(n).inserted {
                out.append(n)
            }
        }
        return out
    }

    /// Back-compat alias for playback set.
    var activeChannels: [Int] { channelsToPlay }

    func isSlotEnabled(_ index: Int) -> Bool {
        guard index < channelEnabled.count else { return true }
        return channelEnabled[index]
    }

    func setSlotEnabled(_ index: Int, _ enabled: Bool) {
        var next = channelEnabled
        while next.count <= index {
            next.append(true)
        }
        next[index] = enabled
        channelEnabled = next
    }

    func setAllSlotsEnabled(_ enabled: Bool) {
        ensureChannelSlots(count: gridCapacity)
        channelEnabled = (0..<gridCapacity).map { _ in enabled }
    }

    func setChannel(at index: Int, to value: Int) {
        guard (1...64).contains(value) else { return }
        var next = channels
        while next.count <= index {
            next.append(next.count + 1)
        }
        next[index] = value
        channels = next
    }

    func ensureChannelSlots(count: Int) {
        var next = channels
        while next.count < count {
            let candidate = (next.max() ?? 0) + 1
            next.append(min(candidate, 64))
        }
        if next.count > count {
            next = Array(next.prefix(count))
        }
        channels = next

        var enabled = channelEnabled
        while enabled.count < count {
            enabled.append(true)
        }
        if enabled.count > count {
            enabled = Array(enabled.prefix(count))
        }
        channelEnabled = enabled
    }

    func clearCredentials() {
        password = ""
    }
}
