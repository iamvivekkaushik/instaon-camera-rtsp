import Foundation
import SwiftUI
import Combine
import Security

/// Minimal generic-password store backed by the macOS Keychain.
private enum KeychainStore {
    private static let service = "com.camerastreamer.credentials"
    /// Account used before device profiles existed — migrated on first launch.
    static let legacyPasswordAccount = "device-password"

    static func account(for profileID: UUID) -> String {
        "profile-\(profileID.uuidString)"
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(account: String) -> String {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func write(account: String, _ value: String) {
        delete(account: account)
        guard !value.isEmpty else { return }
        var attrs = query(account: account)
        attrs[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

/// Persisted app preferences (device profiles, multiview layout, custom view, log panel).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let serial = "cs.serial" // legacy; migrated into a DeviceProfile
        static let username = "cs.username" // legacy
        static let password = "cs.password" // legacy plaintext; migrated to Keychain
        static let profilesJSON = "cs.profilesJSON"
        static let selectedProfileID = "cs.selectedProfileID"
        static let customSlotsJSON = "cs.customSlotsJSON"
        static let viewMode = "cs.viewMode"
        static let channelsCSV = "cs.channelsCSV"
        static let channelEnabledCSV = "cs.channelEnabledCSV"
        static let slotSubtypesCSV = "cs.slotSubtypesCSV"
        static let subtype = "cs.subtype"
        static let streamMode = "cs.streamMode"
        static let gridCapacity = "cs.gridCapacity"
        static let showLogs = "cs.showLogs"
    }

    // MARK: - Device profiles

    /// Saved devices. Passwords are NOT in here — they are in the Keychain per profile id.
    @Published var profiles: [DeviceProfile] {
        didSet { persistProfiles() }
    }
    @Published var selectedProfileID: UUID? {
        didSet { defaults.set(selectedProfileID?.uuidString, forKey: Key.selectedProfileID) }
    }
    /// Bumped when any profile password changes so password bindings re-read the Keychain.
    @Published private(set) var passwordRevision = 0

    var selectedProfile: DeviceProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    func password(for profileID: UUID) -> String {
        KeychainStore.read(account: KeychainStore.account(for: profileID))
    }

    func setPassword(_ value: String, for profileID: UUID) {
        KeychainStore.write(account: KeychainStore.account(for: profileID), value)
        passwordRevision += 1
    }

    /// Edit-in-place helper used by text field bindings.
    func updateProfile(_ profile: DeviceProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
    }

    @discardableResult
    func addProfile() -> DeviceProfile {
        let profile = DeviceProfile(name: "Camera \(profiles.count + 1)")
        profiles.append(profile)
        selectedProfileID = profile.id
        return profile
    }

    func removeProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        KeychainStore.delete(account: KeychainStore.account(for: id))
        // Drop the device from any custom-view slots.
        var changed = false
        for i in customSlots.indices where customSlots[i].profileID == id {
            customSlots[i].profileID = nil
            changed = true
        }
        if changed { persistCustomSlots() }
        if selectedProfileID == id {
            selectedProfileID = profiles.first?.id
        }
    }

    private func persistProfiles() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: Key.profilesJSON)
    }

    // MARK: - Custom view (mixed devices/channels)

    @Published var customSlots: [CustomSlot] {
        didSet { persistCustomSlots() }
    }

    private func persistCustomSlots() {
        defaults.set(try? JSONEncoder().encode(customSlots), forKey: Key.customSlotsJSON)
    }

    func setCustomSlot(index: Int, profileID: UUID?) {
        guard customSlots.indices.contains(index) else { return }
        customSlots[index].profileID = profileID
    }

    func setCustomSlot(index: Int, channel: Int) {
        guard customSlots.indices.contains(index), (1...64).contains(channel) else { return }
        customSlots[index].channel = channel
    }

    func setCustomSlot(index: Int, subtype: Int) {
        guard customSlots.indices.contains(index), (0...1).contains(subtype) else { return }
        customSlots[index].subtype = subtype
    }

    func ensureCustomSlots(count: Int) {
        var next = customSlots
        while next.count < count {
            next.append(CustomSlot(profileID: selectedProfileID ?? profiles.first?.id, channel: next.count + 1))
        }
        if next.count > count {
            next = Array(next.prefix(count))
        }
        customSlots = next
    }

    /// Custom slots that are fully configured (device exists + valid channel).
    var validCustomSlots: [CustomSlot] {
        customSlots.prefix(gridCapacity).filter { slot in
            guard let id = slot.profileID else { return false }
            return (1...64).contains(slot.channel) && profiles.contains { $0.id == id }
        }
    }

    // MARK: - View mode

    @Published var viewMode: LiveViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: Key.viewMode) }
    }

    // MARK: - Single-device channel grid / streaming defaults

    /// Ordered channel list for multiview slots (single-device view).
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
    /// 0 = main, 1 = sub. Global default — also "apply to all slots" control.
    @Published var subtype: Int {
        didSet { defaults.set(subtype, forKey: Key.subtype) }
    }
    /// Per-slot Main(0)/Sub(1) for the single-device grid; slots beyond this
    /// array inherit the global `subtype`.
    @Published var slotSubtypes: [Int] {
        didSet {
            defaults.set(slotSubtypes.map(String.init).joined(separator: ","), forKey: Key.slotSubtypesCSV)
        }
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
        // --- Device profiles (with migration from the legacy single credential) ---
        var loaded: [DeviceProfile] = []
        if let data = defaults.data(forKey: Key.profilesJSON),
           let decoded = try? JSONDecoder().decode([DeviceProfile].self, from: data),
           !decoded.isEmpty {
            loaded = decoded
        } else {
            let legacySerial = defaults.string(forKey: Key.serial) ?? ""
            let legacyUsername = defaults.string(forKey: Key.username) ?? "admin"
            if !legacySerial.isEmpty {
                loaded = [DeviceProfile(name: "Camera 1", serial: legacySerial, username: legacyUsername)]
            }
        }
        profiles = loaded

        let storedSelection = defaults.string(forKey: Key.selectedProfileID).flatMap(UUID.init(uuidString:))
        let initialSelection: UUID?
        if let storedSelection, loaded.contains(where: { $0.id == storedSelection }) {
            initialSelection = storedSelection
        } else {
            initialSelection = loaded.first?.id
        }
        selectedProfileID = initialSelection

        // Migrate legacy passwords (old UserDefaults plaintext, then the old keychain account).
        if let firstID = initialSelection {
            let account = KeychainStore.account(for: firstID)
            if let legacyPlain = defaults.string(forKey: Key.password), !legacyPlain.isEmpty {
                KeychainStore.write(account: account, legacyPlain)
                defaults.removeObject(forKey: Key.password)
            }
            let legacyKC = KeychainStore.read(account: KeychainStore.legacyPasswordAccount)
            if !legacyKC.isEmpty {
                if KeychainStore.read(account: account).isEmpty {
                    KeychainStore.write(account: account, legacyKC)
                }
                KeychainStore.delete(account: KeychainStore.legacyPasswordAccount)
            }
        }
        defaults.removeObject(forKey: Key.serial)
        defaults.removeObject(forKey: Key.username)

        // --- Custom view slots ---
        if let data = defaults.data(forKey: Key.customSlotsJSON),
           let decoded = try? JSONDecoder().decode([CustomSlot].self, from: data) {
            customSlots = decoded
        } else {
            customSlots = []
        }

        viewMode = LiveViewMode(rawValue: defaults.string(forKey: Key.viewMode) ?? "") ?? .device

        // --- Unchanged streaming defaults ---
        let initialSubtype = defaults.object(forKey: Key.subtype) as? Int ?? 1
        subtype = initialSubtype
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

        var ch = parsedChannels
        while ch.count < cap { ch.append(min((ch.max() ?? 0) + 1, 64)) }
        if ch.count > cap { ch = Array(ch.prefix(cap)) }

        var en = parsedEnabled
        while en.count < cap { en.append(true) }
        if en.count > cap { en = Array(en.prefix(cap)) }

        channels = ch
        channelEnabled = en

        if let csv = defaults.string(forKey: Key.slotSubtypesCSV), !csv.isEmpty {
            slotSubtypes = csv
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) == "0" ? 0 : 1 }
        } else {
            slotSubtypes = Array(repeating: initialSubtype, count: cap)
        }
    }

    /// Channel numbers shown in the grid (all slots, single-device view).
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

    // MARK: - Per-slot stream (Main/Sub)

    func slotSubtype(at index: Int) -> Int {
        guard index < slotSubtypes.count else { return subtype }
        return slotSubtypes[index]
    }

    func setSlotSubtype(at index: Int, to value: Int) {
        guard (0...1).contains(value) else { return }
        var next = slotSubtypes
        while next.count <= index {
            next.append(subtype)
        }
        next[index] = value
        slotSubtypes = next
    }

    /// The global Main/Sub selector: updates the default AND applies to all slots.
    func setAllSlotSubtypes(_ value: Int) {
        guard (0...1).contains(value) else { return }
        subtype = value
        slotSubtypes = (0..<gridCapacity).map { _ in value }
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

        var subs = slotSubtypes
        while subs.count < count {
            subs.append(subtype)
        }
        if subs.count > count {
            subs = Array(subs.prefix(count))
        }
        slotSubtypes = subs
    }
}
