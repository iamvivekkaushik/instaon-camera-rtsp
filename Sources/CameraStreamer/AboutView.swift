import SwiftUI

/// About panel — shows the version stamped into the bundle by scripts/package.sh
/// (CFBundleShortVersionString, set from the git tag on release builds).
struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }

            VStack(spacing: 4) {
                Text("CameraStreamer")
                    .font(Theme.titleFont(20, weight: .bold))
                Text("Version \(version)\(build.isEmpty || build == version ? "" : " (\(build))")")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }

            Text("CP Plus / gCMOB camera live view over InstaOn P2P.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(minWidth: 360)
    }
}
