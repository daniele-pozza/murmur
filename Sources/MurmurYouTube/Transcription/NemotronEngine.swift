import AVFoundation
import Foundation
import TranscribeCpp

/// Multilingual streaming transcription via NVIDIA Nemotron 3.5 ASR (GGUF, through
/// transcribe.cpp on ggml/Metal). Same model file the Handy app already downloads to
/// the shared Hugging Face cache — reused directly here, no dependency on Handy itself
/// (Handy's uninstall never touches this cache; it's a generic HF path, not Handy's).
///
/// Replaces the CoreML/ANE WhisperKit path: no ahead-of-time ANE compile (loads in
/// ~1s on ggml/Metal), and streaming is real, so `feed()` yields committed/tentative
/// text as audio arrives instead of only at `finish()`.
actor NemotronEngine: TranscriptionEngine {
    /// Flipped once, from the cache actor, after the model finishes loading. Read from
    /// the main actor to decide whether the HUD should say "loading" for the (short,
    /// ~1s) first press — a stale read for one frame is harmless.
    nonisolated(unsafe) static var isModelReady = false

    private static let modelPath =
        "/Users/danielepozza/.cache/huggingface/hub/models--handy-computer--nemotron-3.5-asr-streaming-0.6b-gguf"
        + "/snapshots/6d44e540bc31b0de1dbe174a3cea87f53a7f22fb/nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf"

    private var stream: TranscribeCpp.Stream?
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        guard FileManager.default.fileExists(atPath: Self.modelPath) else {
            throw TranscriptionError.modelInstallFailed(
                "Nemotron GGUF not found at \(Self.modelPath). Install Handy once "
                    + "(github.com/cjpais/Handy) to populate the shared Hugging Face "
                    + "cache with this model, then retry."
            )
        }

        let model = try await NemotronModelCache.shared.model(path: Self.modelPath)
        let session = try model.session()
        let stream = try session.stream()
        self.stream = stream

        let (asyncStream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation
        return asyncStream
    }

    func feed(_ chunk: AudioChunk) async {
        guard let stream, let channel = chunk.buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(chunk.buffer.frameLength)))
        do {
            let update = try stream.feed(samples)
            // `display` is committed+tentative — the flicker-free "best current guess"
            // the HUD should show, matching TranscriptionChunk.text's "full so far" contract.
            if update.resultChanged {
                continuation?.yield(TranscriptionChunk(text: stream.text.display, isFinal: false))
            }
        } catch {
            Log.speech.error("Nemotron stream feed failed: \(error.localizedDescription)")
        }
    }

    func finish() async {
        defer {
            continuation?.finish()
            continuation = nil
            stream = nil
        }
        guard let stream else { return }
        do {
            try stream.finalize()
            continuation?.yield(TranscriptionChunk(text: stream.text.display, isFinal: true))
        } catch {
            Log.speech.error("Nemotron stream finalize failed: \(error.localizedDescription)")
            continuation?.finish(throwing: error)
        }
    }
}

/// Keeps one loaded `Model` around instead of reopening the GGUF file on every
/// dictation. Matters less than it did for WhisperKit (ggml/Metal load is ~1s, no
/// ANE ahead-of-time compile) but there's still no reason to redo it each press.
private actor NemotronModelCache {
    static let shared = NemotronModelCache()

    private var loaded: Model?
    private var loadTask: Task<Model, Error>?

    func model(path: String) async throws -> Model {
        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value }

        let task = Task<Model, Error> {
            Log.speech.info("loading Nemotron model…")
            let model = try Model(path: path)
            Log.speech.info("Nemotron model ready (backend: \(model.backend, privacy: .public))")
            NemotronEngine.isModelReady = true
            return model
        }
        loadTask = task
        defer { loadTask = nil }

        let model = try await task.value
        loaded = model
        return model
    }
}
