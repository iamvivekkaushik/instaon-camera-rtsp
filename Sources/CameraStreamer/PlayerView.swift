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
        view.allowsPictureInPicturePlayback = true
        view.player = context.coordinator.player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.attach(url: url)
        if nsView.player !== context.coordinator.player {
            nsView.player = context.coordinator.player
        }
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
        private var timeControlObserver: NSKeyValueObservation?
        private var liveCatchUpTimer: Timer?
        private var currentURL: URL?

        override init() {
            super.init()
            player.isMuted = true
            // Live HLS: start quickly; we catch up to the edge on stalls.
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
            if currentURL?.absoluteString == url.absoluteString, player.currentItem != nil {
                if player.timeControlStatus != .playing {
                    seekToLiveEdge(reason: "resume")
                }
                return
            }
            currentURL = url
            clearObservers()

            let asset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            )
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 2
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            if #available(macOS 13.0, *) {
                item.preferredPeakBitRate = 2_500_000
            }

            statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    NSLog("CameraStreamer player readyToPlay: %@", url.absoluteString)
                    self.seekToLiveEdge(reason: "ready")
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
                NSLog("CameraStreamer player stalled — catch up to live edge")
                self?.seekToLiveEdge(reason: "stall")
            }

            timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                guard let self else { return }
                if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    NSLog("CameraStreamer player waiting — catch up to live edge")
                    self.seekToLiveEdge(reason: "waiting")
                }
            }

            // Live HLS can drift behind after a gap; nudge to the edge periodically.
            liveCatchUpTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
                self?.seekToLiveEdgeIfBehind()
            }
            if let liveCatchUpTimer {
                RunLoop.main.add(liveCatchUpTimer, forMode: .common)
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

        private func seekToLiveEdge(reason: String) {
            guard let item = player.currentItem else {
                player.play()
                return
            }
            if let range = item.seekableTimeRanges.last?.timeRangeValue,
               range.duration.seconds.isFinite,
               range.duration.seconds > 0.5 {
                let edge = CMTimeAdd(range.start, range.duration)
                let nearLive = CMTimeSubtract(edge, CMTime(seconds: 0.8, preferredTimescale: 600))
                player.seek(to: nearLive, toleranceBefore: .positiveInfinity, toleranceAfter: .zero) { [weak self] _ in
                    self?.player.play()
                    NSLog("CameraStreamer seek live edge (%@)", reason)
                }
            } else {
                player.play()
            }
        }

        private func seekToLiveEdgeIfBehind() {
            guard let item = player.currentItem,
                  item.status == .readyToPlay,
                  let range = item.seekableTimeRanges.last?.timeRangeValue,
                  range.duration.seconds.isFinite,
                  range.duration.seconds > 1 else {
                if player.timeControlStatus != .playing {
                    player.play()
                }
                return
            }
            let edge = CMTimeAdd(range.start, range.duration)
            let behind = CMTimeSubtract(edge, player.currentTime()).seconds
            if behind > 3.5 || player.timeControlStatus != .playing {
                seekToLiveEdge(reason: "timer behind=\(String(format: "%.1f", behind))")
            }
        }

        private func clearObservers() {
            statusObserver = nil
            errorObserver = nil
            timeControlObserver = nil
            liveCatchUpTimer?.invalidate()
            liveCatchUpTimer = nil
            if let stallObserver {
                NotificationCenter.default.removeObserver(stallObserver)
                self.stallObserver = nil
            }
        }
    }
}
