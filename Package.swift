// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "CameraStreamer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CameraStreamer", targets: ["CameraStreamer"])
    ],
    targets: [
        .executableTarget(
            name: "CameraStreamer",
            path: "Sources/CameraStreamer"
        )
    ]
)
