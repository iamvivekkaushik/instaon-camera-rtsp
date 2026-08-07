import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showPassword = false
    @State private var didSaveFlash = false

    var body: some View {
        Form {
            Section {
                TextField("InstaOn / serial ID", text: $settings.serial)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Device serial or InstaOn ID")

                TextField("Device username", text: $settings.username)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("RTSP device username")

                HStack(spacing: 8) {
                    Group {
                        if showPassword {
                            TextField("Device password", text: $settings.password)
                        } else {
                            SecureField("Device password", text: $settings.password)
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

                HStack {
                    Button("Clear password") {
                        settings.clearCredentials()
                    }
                    .disabled(settings.password.isEmpty)

                    Spacer()

                    if didSaveFlash {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                            .accessibilityLabel("Credentials saved")
                    }
                }
                .padding(.top, 4)
            } header: {
                Text("Device credentials")
            } footer: {
                Text("Stored locally in this app’s preferences. Used for RTSP digest auth over the P2P tunnel. Passwords with @ are supported.")
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
                }
                .accessibilityLabel("Multiview grid size")

                Toggle("Show diagnostic logs by default", isOn: $settings.showLogs)
                    .accessibilityLabel("Show diagnostic logs by default")
            } header: {
                Text("Streaming defaults")
            }

            Section {
                Text("Close gCMOB live view while streaming. Prefer Sub over P2P relay. One P2P tunnel is shared across multiview channels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420, minHeight: 360)
        .onChange(of: settings.serial) { _ in flashSaved() }
        .onChange(of: settings.username) { _ in flashSaved() }
        .onChange(of: settings.password) { _ in flashSaved() }
    }

    private func flashSaved() {
        didSaveFlash = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didSaveFlash = false
        }
    }
}
