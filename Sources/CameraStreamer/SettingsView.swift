import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showPassword = false
    @State private var didSaveFlash = false

    var body: some View {
        Form {
            Section {
                if settings.profiles.isEmpty {
                    Text("No profiles yet — add one to save device credentials.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.profiles) { profile in
                    let isSelected = settings.selectedProfileID == profile.id
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.displayName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text(profile.serial.isEmpty ? "No serial" : profile.serial)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.removeProfile(profile.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete profile and its saved password")
                        .accessibilityLabel("Delete profile \(profile.displayName)")
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Theme.accent.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { settings.selectedProfileID = profile.id }
                }
                Button {
                    _ = settings.addProfile()
                } label: {
                    Label("Add Profile", systemImage: "plus")
                }
                .accessibilityLabel("Add device profile")
                if didSaveFlash {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .accessibilityLabel("Settings saved")
                }
            } header: {
                Text("Device profiles")
            } footer: {
                Text("The checked profile is used in the Device live view. Passwords are stored in the macOS Keychain; everything else is stored locally.")
            }

            if let profileID = settings.selectedProfileID {
                Section {
                    TextField("Profile name", text: profileBinding(\.name, for: profileID))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Profile name")

                    TextField("InstaOn / serial ID", text: profileBinding(\.serial, for: profileID))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Device serial or InstaOn ID")

                    TextField("Device username", text: profileBinding(\.username, for: profileID))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("RTSP device username")

                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField("Device password", text: passwordBinding(for: profileID))
                            } else {
                                SecureField("Device password", text: passwordBinding(for: profileID))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("RTSP device password")

                        Toggle(isOn: $showPassword) {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.borderless)
                        .help(showPassword ? "Hide password" : "Show password")
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }

                    Button("Clear password") {
                        settings.setPassword("", for: profileID)
                    }
                    .disabled(settings.password(for: profileID).isEmpty)
                } header: {
                    Text("Selected profile")
                } footer: {
                    Text("Used for RTSP digest auth over the P2P tunnel. Passwords with @ are supported.")
                }
            }

            Section {
                Picker("Default stream", selection: $settings.subtype) {
                    Text("Main (higher quality)").tag(0)
                    Text("Sub (recommended over P2P)").tag(1)
                }
                .accessibilityLabel("Default stream quality")

                Picker("Default mode", selection: $settings.streamMode) {
                    ForEach(StreamMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .accessibilityLabel("Default connection mode")

                Picker("Multiview layout", selection: $settings.gridCapacity) {
                    Text("1 camera").tag(1)
                    Text("2 × 2 (4)").tag(4)
                    Text("3 × 3 (9)").tag(9)
                }
                .onChange(of: settings.gridCapacity) { capacity in
                    settings.ensureChannelSlots(count: capacity)
                    settings.ensureCustomSlots(count: capacity)
                }
                .accessibilityLabel("Multiview grid size")

                Toggle("Show diagnostic logs by default", isOn: $settings.showLogs)
                    .accessibilityLabel("Show diagnostic logs by default")
            } header: {
                Text("Streaming defaults")
            }

            Section {
                Text("Close gCMOB live view while streaming. Prefer Sub over P2P relay. In Custom view each device gets its own tunnel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420, minHeight: 460)
        .onChange(of: settings.profiles) { _ in flashSaved() }
        .onChange(of: settings.passwordRevision) { _ in flashSaved() }
        .onChange(of: settings.selectedProfileID) { _ in flashSaved() }
    }

    private func profileBinding(
        _ keyPath: WritableKeyPath<DeviceProfile, String>,
        for id: UUID
    ) -> Binding<String> {
        Binding(
            get: { settings.profiles.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var profile = settings.profiles.first(where: { $0.id == id }) else { return }
                profile[keyPath: keyPath] = newValue
                settings.updateProfile(profile)
            }
        )
    }

    private func passwordBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                _ = settings.passwordRevision
                return settings.password(for: id)
            },
            set: { settings.setPassword($0, for: id) }
        )
    }

    private func flashSaved() {
        didSaveFlash = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didSaveFlash = false
        }
    }
}
