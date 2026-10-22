import AVFoundation

enum RecorderError: LocalizedError {
    case noInputDevice

    var errorDescription: String? { "No microphone input is available" }
}

/// Captures the default input device while the hotkey is held.
/// A fresh AVAudioEngine is built for each recording so a changed default mic (e.g. headphones) is picked up.
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private var nativeRate: Double = 0
    private let lock = NSLock()

    var isRecording: Bool { engine != nil }

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        nativeRate = format.sampleRate
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let mono = AudioRecorder.mixToMono(buffer)
            guard let self else { return }
            self.lock.lock()
            self.samples.append(contentsOf: mono)
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops capture and returns the raw mono samples plus their sample rate.
    func stop() -> (samples: [Float], sampleRate: Double) {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples = []
        return (captured, nativeRate)
    }

    // MARK: - Conversion helpers (shared with the --transcribe file mode)

    static func mixToMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        if buffer.format.isInterleaved {
            let interleaved = data[0]
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += interleaved[i * channels + c] }
                mono[i] = sum / Float(channels)
            }
        } else {
            for c in 0..<channels {
                let channel = data[c]
                for i in 0..<frames { mono[i] += channel[i] }
            }
            if channels > 1 {
                let scale = 1 / Float(channels)
                for i in 0..<frames { mono[i] *= scale }
            }
        }
        return mono
    }

    /// Resamples mono Float32 audio to the 16 kHz Whisper expects.
    static func resampleTo16k(_ input: [Float], from rate: Double) -> [Float] {
        let target = Double(Transcriber.sampleRate)
        guard !input.isEmpty else { return [] }
        if rate == target { return input }

        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(input.count)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat,
                                               frameCapacity: AVAudioFrameCount(Double(input.count) * target / rate) + 4096)
        else { return [] }

        inBuffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: input.count)
        }

        var delivered = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if delivered {
                status.pointee = .endOfStream
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return inBuffer
        }
        if error != nil { return [] }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }

    /// Cheap energy gate: skip Whisper entirely when nobody spoke, which avoids its
    /// well-known "Thank you." hallucinations on silence. Expects 16 kHz audio.
    static func containsSpeech(_ samples: [Float], threshold: Float = 0.0025, minimumFrames: Int = 4) -> Bool {
        let frame = 480 // 30 ms
        var loudFrames = 0
        var start = 0
        while start + frame <= samples.count {
            var energy: Float = 0
            for i in start..<(start + frame) { energy += samples[i] * samples[i] }
            if (energy / Float(frame)).squareRoot() > threshold {
                loudFrames += 1
                if loudFrames >= minimumFrames { return true }
            }
            start += frame
        }
        return false
    }
}
