import AVFoundation
import AVKit
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let url: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        // Ensure controls remain interactive when embedded in SwiftUI layouts.
        view.allowsPictureInPicturePlayback = true
        view.player = context.coordinator.player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.attach(url: url)
        if nsView.player !== context.coordinator.player {
            nsView.player = context.coordinator.player
        }
        // Re-assert full-screen affordance after SwiftUI updates.
        nsView.controlsStyle = .inline
        nsView.showsFullScreenToggleButton = true
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.teardown()
        nsView.player = nil
    }

    final class Coordinator: NSObject {
        let player = AVPlayer()
        private var statusObserver: NSKeyValueObservation?
        private var errorObserver: NSKeyValueObservation?
        private var stallObserver: NSObjectProtocol?
        private var currentURL: URL?

        override init() {
            super.init()
            player.isMuted = true
            // Live HLS: start as soon as a segment is ready (don't buffer for smooth VOD).
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .none
        }

        func attach(url: URL?) {
            guard let url else {
                player.pause()
                player.replaceCurrentItem(with: nil)
                currentURL = nil
                clearObservers()
                return
            }
            // Compare by absoluteString: file vs http and trailing-slash variants.
            if currentURL?.absoluteString == url.absoluteString, player.currentItem != nil {
                if player.timeControlStatus != .playing {
                    player.play()
                }
                return
            }
            currentURL = url
            clearObservers()

            // Live HTTP HLS playlist (localhost). Prefer fast start over precise duration.
            let asset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            )
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 1
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            if #available(macOS 13.0, *) {
                item.preferredPeakBitRate = 2_000_000
            }

            statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    NSLog("CameraStreamer player readyToPlay: %@", url.absoluteString)
                    self.player.play()
                    // Seek near live edge if a seekable range exists.
                    if let range = item.seekableTimeRanges.last?.timeRangeValue,
                       range.duration.seconds.isFinite,
                       range.duration.seconds > 1 {
                        let edge = CMTimeAdd(range.start, range.duration)
                        let nearLive = CMTimeSubtract(edge, CMTime(seconds: 1, preferredTimescale: 600))
                        self.player.seek(to: nearLive, toleranceBefore: .positiveInfinity, toleranceAfter: .zero) { _ in
                            self.player.play()
                        }
                    }
                case .failed:
                    let nsErr = item.error as NSError?
                    NSLog(
                        "CameraStreamer player failed: %@ | domain=%@ code=%ld underlying=%@",
                        item.error?.localizedDescription ?? "unknown",
                        nsErr?.domain ?? "",
                        nsErr?.code ?? 0,
                        String(describing: nsErr?.userInfo[NSUnderlyingErrorKey])
                    )
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }

            errorObserver = item.observe(\.error, options: [.new]) { item, _ in
                guard let error = item.error else { return }
                NSLog("CameraStreamer player item error: %@", error.localizedDescription)
            }

            stallObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { [weak self] _ in
                NSLog("CameraStreamer player stalled — resuming")
                self?.player.play()
            }

            player.replaceCurrentItem(with: item)
            player.play()
        }

        func teardown() {
            clearObservers()
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentURL = nil
        }

        private func clearObservers() {
            statusObserver = nil
            errorObserver = nil
            if let stallObserver {
                NotificationCenter.default.removeObserver(stallObserver)
                self.stallObserver = nil
            }
        }
    }
}
