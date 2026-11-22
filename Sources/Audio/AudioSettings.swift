import Foundation
import SwiftUI

/// The equalizer and the volume levelling, as on the desktop
/// (crates/hk-core/src/settings.rs): 10 bands, the same presets.
@MainActor
final class AudioSettings: ObservableObject {
    static let shared = AudioSettings()

    static let bands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let gainMax: Double = 12
    static let presets: [(id: String, name: String, gains: [Double])] = [
        ("flat", "Ровно", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("bass", "Басы", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("vocal", "Голос", [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        ("rock", "Рок", [4, 3, 1, -1, -2, -1, 1, 3, 4, 4]),
        ("pop", "Поп", [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
        ("electronic", "Электроника", [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        ("acoustic", "Акустика", [3, 3, 2, 1, 1, 1, 2, 3, 2, 1]),
        ("night", "Ночь", [2, 2, 1, 0, 0, -1, -2, -3, -4, -5]),
    ]

    @Published var eqOn: Bool { didSet { save(); apply() } }
    /// a preset id, or "custom"
    @Published var preset: String { didSet { save() } }
    @Published var gains: [Double] { didSet { save(); apply() } }
    /// quiet songs and loud songs at one level (YouTube's loudness numbers)
    @Published var normalize: Bool { didSet { save(); Player.shared.levelChanged() } }

    private let defaults = UserDefaults.standard

    init() {
        eqOn = defaults.bool(forKey: "eq.on")
        preset = defaults.string(forKey: "eq.preset") ?? "flat"
        let saved = defaults.array(forKey: "eq.gains") as? [Double] ?? []
        gains = saved.count == 10 ? saved.map { min(max($0, -12), 12) } : Array(repeating: 0, count: 10)
        normalize = defaults.object(forKey: "audio.normalize") as? Bool ?? true
    }

    func choose(_ id: String) {
        guard let found = Self.presets.first(where: { $0.id == id }) else { return }
        preset = id
        gains = found.gains
        if !eqOn && id != "flat" { eqOn = true }
    }

    func setGain(_ band: Int, _ value: Double) {
        guard gains.indices.contains(band) else { return }
        var g = gains
        g[band] = (min(max(value, -Self.gainMax), Self.gainMax) * 2).rounded() / 2
        gains = g
        preset = Self.presets.first(where: { $0.gains == g })?.id ?? "custom"
    }

    var presetName: String {
        Self.presets.first(where: { $0.id == preset })?.name ?? "Свой"
    }

    private func save() {
        defaults.set(eqOn, forKey: "eq.on")
        defaults.set(preset, forKey: "eq.preset")
        defaults.set(gains, forKey: "eq.gains")
        defaults.set(normalize, forKey: "audio.normalize")
    }

    func apply() {
        Player.shared.engine.setEqualizer(on: eqOn, gains: gains)
    }
}

/// YouTube's loudness of each song, kept when its audio is fetched, so a
/// cached file is played at the same level later.
enum Loudness {
    private static let key = "loudness.v1"
    private static let lock = NSLock()

    static func save(_ videoId: String, _ db: Double) {
        lock.lock(); defer { lock.unlock() }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        if all.count > 4000 { all.removeAll() }
        all[videoId] = (db * 10).rounded() / 10
        UserDefaults.standard.set(all, forKey: key)
    }

    static func db(_ videoId: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[videoId]
    }

    /// the volume that brings a song down to the common level (never louder than as it is)
    static func gain(for track: Track) -> Float {
        guard let id = track.videoId, let db = db(id), db > 0 else { return 1 }
        return Float(max(0.25, pow(10, -db / 20)))
    }
}
