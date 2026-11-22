import AVFoundation

/// Plays one file from the phone through AVAudioEngine, so the equalizer and
/// the volume levelling sit between the file and the speaker. Pausing and
/// seeking schedule the file again from a frame, so the position is always
/// `startFrame` plus what the node has played since.
@MainActor
final class EnginePlayer {
    let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var startFrame: AVAudioFramePosition = 0
    private var lastFrame: AVAudioFramePosition = 0
    /// callbacks of a segment scheduled before the last stop are ignored
    private var generation = 0
    private(set) var isPlaying = false
    private var level: Float = 1
    private var fade: Float = 1

    /// the file played to its end
    var onFinish: (@MainActor () -> Void)?

    init() {
        engine.attach(node)
        engine.attach(eq)
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Float(AudioSettings.bands[i])
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        eq.bypass = true
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configurationChanged() }
        }
    }

    var hasFile: Bool { file != nil }

    var duration: Double {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var currentTime: Double {
        guard let file else { return 0 }
        return Double(currentFrame) / file.processingFormat.sampleRate
    }

    private var currentFrame: AVAudioFramePosition {
        guard let file else { return 0 }
        if isPlaying, let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
           let playerTime = node.playerTime(forNodeTime: nodeTime) {
            let frame = min(file.length, startFrame + max(0, playerTime.sampleTime))
            lastFrame = frame
            return frame
        }
        return isPlaying ? lastFrame : startFrame
    }

    func open(_ url: URL) throws {
        stop()
        let opened = try AVAudioFile(forReading: url)
        let wanted = opened.processingFormat
        if format != wanted {
            engine.stop()
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(eq)
            engine.connect(node, to: eq, format: wanted)
            engine.connect(eq, to: engine.mainMixerNode, format: wanted)
            format = wanted
        }
        file = opened
        startFrame = 0
        lastFrame = 0
    }

    func play(from seconds: Double? = nil) throws {
        guard let file else { return }
        let frame = seconds.map { AVAudioFramePosition(max(0, $0) * file.processingFormat.sampleRate) } ?? startFrame
        schedule(from: frame)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        node.play()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        let frame = currentFrame
        isPlaying = false
        generation += 1
        node.stop()
        startFrame = frame
        lastFrame = frame
        engine.pause()
    }

    func seek(to seconds: Double) {
        guard let file else { return }
        let frame = AVAudioFramePosition(max(0, seconds) * file.processingFormat.sampleRate)
        if isPlaying {
            schedule(from: frame)
            node.play()
        } else {
            startFrame = min(frame, file.length)
            lastFrame = startFrame
        }
    }

    func stop() {
        generation += 1
        node.stop()
        isPlaying = false
        file = nil
        startFrame = 0
        lastFrame = 0
        if engine.isRunning { engine.pause() }
    }

    /// the levelling volume of this song
    func setLevel(_ value: Float) {
        level = value
        node.volume = level * fade
    }

    /// the sleep timer's fade, 0…1
    func setFade(_ value: Float) {
        fade = value
        node.volume = level * fade
    }

    func setEqualizer(on: Bool, gains: [Double]) {
        for (i, band) in eq.bands.enumerated() where i < gains.count {
            band.gain = Float(gains[i])
        }
        // the louder bands would clip: the whole curve goes down by its top
        let top = gains.max() ?? 0
        eq.globalGain = on ? Float(-max(0, top) * 0.6) : 0
        eq.bypass = !on
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        generation += 1
        node.stop()
        let gen = generation
        let start = min(max(0, frame), file.length)
        startFrame = start
        lastFrame = start
        let count = AVAudioFrameCount(clamping: max(0, file.length - start))
        guard count > 0 else {
            Task { @MainActor in
                guard self.generation == gen else { return }
                self.isPlaying = false
                self.onFinish?()
            }
            return
        }
        node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.isPlaying = false
                self.startFrame = file.length
                self.onFinish?()
            }
        }
    }

    /// headphones in or out, AirPlay, a call: iOS stops the engine and changes its output
    private func configurationChanged() {
        guard file != nil else { return }
        let wasPlaying = isPlaying
        let frame = lastFrame
        isPlaying = false
        generation += 1
        node.stop()
        startFrame = frame
        if wasPlaying {
            try? play()
        }
    }
}
