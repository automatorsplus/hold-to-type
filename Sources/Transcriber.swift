import Foundation

enum TranscriberError: LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case notLoaded
    case whisperFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): return "Whisper model not found at \(path)"
        case .modelLoadFailed(let path): return "Could not load Whisper model at \(path)"
        case .notLoaded: return "Whisper model is not loaded yet"
        case .whisperFailed(let code): return "whisper_full failed with code \(code)"
        }
    }
}

/// Owns one whisper.cpp context, kept in memory so each dictation only pays for inference.
/// Every call must be made on `queue`; whisper contexts are not thread-safe.
final class Transcriber {
    let queue = DispatchQueue(label: "holdtotype.whisper", qos: .userInitiated)
    private var ctx: OpaquePointer?

    static let sampleRate = 16_000

    init() {
        if ProcessInfo.processInfo.environment["HOLDTOTYPE_WHISPER_LOGS"] == nil {
            whisper_log_set({ _, _, _ in }, nil)
        }
        // Homebrew's ggml ships CPU/Metal/BLAS backends as plugins that must be loaded explicitly.
        ggml_backend_load_all()
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    func load(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriberError.modelNotFound(modelPath)
        }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let loaded = whisper_init_from_file_with_params(modelPath, params) else {
            throw TranscriberError.modelLoadFailed(modelPath)
        }
        ctx = loaded
        // Run one pass over silence so Metal pipelines are compiled before the first real dictation.
        _ = try? transcribe(samples: [Float](repeating: 0, count: Transcriber.sampleRate), language: "en", prompt: nil)
    }

    /// `samples` must be 16 kHz mono Float32 in [-1, 1].
    func transcribe(samples: [Float], language: String, prompt: String?) throws -> String {
        guard let ctx else { throw TranscriberError.notLoaded }

        // whisper.cpp warns on clips under 1 s; pad with trailing silence, which also helps the last word.
        var audio = samples
        let minimum = Transcriber.sampleRate + Transcriber.sampleRate / 4
        audio.append(contentsOf: [Float](repeating: 0, count: max(Transcriber.sampleRate / 4, minimum - audio.count)))

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = 4
        params.no_context = true
        params.no_timestamps = true
        params.single_segment = false
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true

        let promptText = prompt ?? ""
        let status: Int32 = language.withCString { lang in
            promptText.withCString { promptPtr in
                params.language = lang
                params.initial_prompt = promptText.isEmpty ? nil : promptPtr
                return audio.withUnsafeBufferPointer { buffer in
                    whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard status == 0 else { throw TranscriberError.whisperFailed(status) }

        var pieces: [String] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            let piece = String(cString: whisper_full_get_segment_text(ctx, i))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty || Transcriber.isNonSpeechMarker(piece) { continue }
            pieces.append(piece)
        }
        return pieces.joined(separator: " ")
    }

    /// Whisper emits markers like "[BLANK_AUDIO]" or "(wind blowing)" for non-speech audio.
    private static func isNonSpeechMarker(_ text: String) -> Bool {
        (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")"))
    }
}
