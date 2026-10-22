import AppKit
import AVFoundation

/// `HoldToType --transcribe file.wav` runs the same audio + Whisper path on a file and prints the text.
/// Useful for checking the model works without granting any permissions.
func transcribeFile(_ path: String) -> Int32 {
    let transcriber = Transcriber()
    do {
        let loadStart = Date()
        try transcriber.load(modelPath: Settings.modelPath)
        let loadTime = Date().timeIntervalSince(loadStart)

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RecorderError.noInputDevice
        }
        try file.read(into: buffer)
        let audio = AudioRecorder.resampleTo16k(AudioRecorder.mixToMono(buffer), from: file.processingFormat.sampleRate)

        let start = Date()
        let speech = AudioRecorder.containsSpeech(audio)
        let text = speech ? try transcriber.transcribe(samples: audio, language: Settings.language, prompt: Settings.vocabulary) : ""
        let elapsed = Date().timeIntervalSince(start)

        print(text)
        FileHandle.standardError.write(String(
            format: "[%.0f Hz, %d ch, %.2fs audio, speech=%@] model load %.2fs, transcribe %.2fs\n",
            file.processingFormat.sampleRate, file.processingFormat.channelCount,
            Double(audio.count) / Double(Transcriber.sampleRate), speech ? "yes" : "no", loadTime, elapsed
        ).data(using: .utf8)!)
        return 0
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        return 1
    }
}

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--transcribe"), flag + 1 < arguments.count {
    exit(transcribeFile(arguments[flag + 1]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
