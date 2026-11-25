import AVFoundation
import Foundation

/// Wake sounds, error and stop sounds, and the alarm, using the Android app's
/// own sound files (wakeSounds/, other/, alarm/).
final class SoundEffects {
    struct Sound {
        let id: String
        let name: String
        let url: URL
    }

    let wakeSounds: [Sound]
    let alarms: [Sound]

    private var effectPlayer: AVAudioPlayer?
    private var alarmPlayer: AVAudioPlayer?

    /// 0...1
    var effectVolume: Float = 1
    var alarmVolume: Float = 1 { didSet { alarmPlayer?.volume = alarmVolume } }

    var isAlarmSounding: Bool { alarmPlayer?.isPlaying ?? false }

    init() {
        wakeSounds = Self.list("wakeSounds")
        alarms = Self.list("alarm")
    }

    private static func list(_ folder: String) -> [Sound] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent(folder),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { ["mp3", "wav"].contains($0.pathExtension.lowercased()) }.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            return Sound(id: id, name: displayName(id), url: url)
        }.sorted { $0.name < $1.name }
    }

    /// "home_assistant" -> "Home Assistant", as the Android app shows them.
    static func displayName(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Plays a wake sound by id ("none" plays nothing). Returns its length.
    @discardableResult
    func playWakeSound(_ id: String) -> TimeInterval {
        guard id != "none", let sound = wakeSounds.first(where: { $0.id == id }) else { return 0 }
        return play(sound.url)
    }

    func playError() { playOther("error") }
    func playStop() { playOther("stop_word") }

    private func playOther(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "other") else { return }
        play(url)
    }

    @discardableResult
    private func play(_ url: URL) -> TimeInterval {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = effectVolume
            player.play()
            effectPlayer = player
            return player.duration
        } catch {
            Log.shared.add("Could not play \(url.lastPathComponent): \(error.localizedDescription)")
            return 0
        }
    }

    /// Start the alarm (loops until stopped). Unknown ids use the default.
    func startAlarm(_ id: String) {
        let sound = alarms.first { $0.id == id } ?? alarms.first { $0.id == "default" } ?? alarms.first
        guard let sound else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: sound.url)
            player.numberOfLoops = -1
            player.volume = alarmVolume
            player.play()
            alarmPlayer = player
        } catch {
            Log.shared.add("Could not play alarm: \(error.localizedDescription)")
        }
    }

    func stopAlarm() {
        alarmPlayer?.stop()
        alarmPlayer = nil
    }
}
