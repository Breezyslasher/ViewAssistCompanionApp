import AVFoundation
import Foundation

/// The Home Assistant media player: music, radio and alerts by URL.
/// Announcements play on a second player over any music, which is ducked.
final class MediaController {
    private let music = AVPlayer()
    private var announcer: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var announceObserver: NSObjectProtocol?

    /// Called when playing state changes, so status can be sent to HA.
    var onStateChange: ((Bool) -> Void)?

    /// 0...1
    var musicVolume: Float = 0.5 { didSet { applyVolumes() } }
    /// Music volume while an announcement or response plays, 0...1.
    var duckingVolume: Float = 0.2 { didSet { applyVolumes() } }
    var announceVolume: Float = 1 { didSet { announcer?.volume = announceVolume } }

    private var ducked = false

    var isPlaying: Bool { music.timeControlStatus != .paused && music.currentItem != nil }

    init() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? AVPlayerItem) === self.music.currentItem else { return }
            self.music.replaceCurrentItem(with: nil)
            self.onStateChange?(false)
        }
    }

    func play(url: URL, volume: Float?, announce: Bool) {
        if announce {
            playAnnouncement(url)
            return
        }
        if let volume { musicVolume = max(0, min(1, volume)) }
        music.replaceCurrentItem(with: AVPlayerItem(url: url))
        music.play()
        applyVolumes()
        onStateChange?(true)
    }

    func resume(volume: Float?) {
        if let volume { musicVolume = max(0, min(1, volume)) }
        guard music.currentItem != nil else { return }
        music.play()
        onStateChange?(true)
    }

    func pause() {
        music.pause()
        onStateChange?(false)
    }

    func stop() {
        music.pause()
        music.replaceCurrentItem(with: nil)
        announcer?.pause()
        announcer = nil
        setDucked(false)
        onStateChange?(false)
    }

    /// Lower music while the assistant listens or speaks.
    func setDucked(_ value: Bool) {
        ducked = value
        applyVolumes()
    }

    private func applyVolumes() {
        music.volume = ducked ? min(musicVolume, duckingVolume) : musicVolume
    }

    private func playAnnouncement(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = announceVolume
        announcer = player
        setDucked(true)
        if let announceObserver { NotificationCenter.default.removeObserver(announceObserver) }
        announceObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.announcer = nil
            self?.setDucked(false)
        }
        player.play()
    }
}
