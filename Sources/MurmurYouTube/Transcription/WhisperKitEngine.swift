import AVFoundation
import Foundation
import WhisperKit

/// `WhisperKit` isn't `Sendable` upstream, but every instance here lives entirely inside
/// `WhisperKitModelCache`, one actor, one property — there's no cross-isolation mutation
/// for the compiler to actually be protecting against.
extension WhisperKit: @unchecked @retroactive Sendable {}

/// Multilingual transcription via Whisper large-v3-turbo (CoreML/ANE, through WhisperKit).
///
/// Whisper resolves on release rather than streaming live text like Apple's engine did —
/// it needs the whole utterance to run its language-detection pass, so `feed()` just
/// accumulates samples and the actual transcription happens once in `finish()`.
///
/// Language is never fixed: `DecodingOptions.detectLanguage` runs WhisperKit's own
/// detector on each utterance, so a single hotkey covers Italian, English, or a mix
/// with a dominant language, without any manual toggle.
actor WhisperKitEngine: TranscriptionEngine {
    /// `large-v3-v20240930_turbo` — Argmax's recommendation for max speed+accuracy on macOS.
    private static let modelName = "large-v3-v20240930_turbo"

    private var samples: [Float] = []
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)
        // Loaded (and cached) up front so a failure to download/load surfaces immediately
        // rather than silently at `finish()`.
        try await WhisperKitModelCache.shared.ensureLoaded(model: Self.modelName)

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        guard let channel = chunk.buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(chunk.buffer.frameLength)))
    }

    func finish() async {
        defer {
            continuation?.finish()
            continuation = nil
        }

        guard !samples.isEmpty else {
            continuation?.yield(TranscriptionChunk(text: "", isFinal: true))
            return
        }

        do {
            let options = DecodingOptions(usePrefillPrompt: false, detectLanguage: true)
            let text = try await WhisperKitModelCache.shared.transcribe(
                model: Self.modelName,
                audioArray: samples,
                decodeOptions: options
            )
            continuation?.yield(TranscriptionChunk(text: text, isFinal: true))
        } catch {
            Log.speech.error("WhisperKit transcription failed: \(error.localizedDescription)")
            continuation?.finish(throwing: error)
        }
    }
}

/// Keeps one loaded `WhisperKit` pipeline around instead of re-loading the model (and
/// re-downloading it on first run) on every single dictation.
///
/// `WhisperKit` itself isn't `Sendable`, so it never leaves this actor — every call site
/// asks the cache to run the transcription rather than borrowing the pipeline out.
private actor WhisperKitModelCache {
    static let shared = WhisperKitModelCache()

    private var pipe: WhisperKit?

    func ensureLoaded(model: String) async throws {
        _ = try await loaded(model: model)
    }

    func transcribe(model: String, audioArray: [Float], decodeOptions: DecodingOptions) async throws -> String {
        let pipe = try await loaded(model: model)
        let results = try await pipe.transcribe(audioArray: audioArray, decodeOptions: decodeOptions)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loaded(model: String) async throws -> WhisperKit {
        if let pipe { return pipe }
        Log.speech.info("loading WhisperKit model \(model, privacy: .public)…")
        let new = try await WhisperKit(WhisperKitConfig(model: model))
        pipe = new
        Log.speech.info("WhisperKit model ready")
        return new
    }
}
