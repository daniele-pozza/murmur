import AVFoundation
import Foundation
import TranscribeCpp

/// Multilingual streaming transcription via NVIDIA Nemotron 3.5 ASR (GGUF, through
/// transcribe.cpp on ggml/Metal).
///
/// Replaces the CoreML/ANE WhisperKit path: no ahead-of-time ANE compile, and streaming
/// is real, so `feed()` yields committed/tentative text as audio arrives instead of only
/// at `finish()`.
///
/// Measured on this machine (footprint after load, warm reload):
/// Q4_K_M 655MB/0.6s · **Q5_K_M 716MB/0.7s** · Q8_0 895MB/1.5s. Footprint is always
/// file size + ~181MB of fixed ggml-Metal pipeline and graph memory, so a smaller quant
/// only buys back its own file-size difference. `SessionOptions.nCtx` is *not* a knob
/// here: this model loads as `arch == "parakeet"`, an unbounded family that the C header
/// documents as ignoring `n_ctx` outright.
actor NemotronEngine: TranscriptionEngine {
    /// Kept in Application Support, deliberately *not* read from the shared Hugging Face
    /// cache. The cache stores blobs by content hash behind a per-file symlink, so a
    /// `hf download` or any other tool re-verifying that repo silently restores whatever
    /// the manifest says — swapping the model out from under us and moving RAM by
    /// hundreds of MB with nothing in the log to explain it.
    private static let modelPath = URL.applicationSupportDirectory
        .appending(path: "MurmurYouTube/nemotron-3.5-asr-streaming-0.6b-Q5_K_M.gguf")
        .path(percentEncoded: false)

    private var stream: TranscribeCpp.Stream?
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
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
            Task { await NemotronModelCache.shared.scheduleIdleUnload() }
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

    func shutdown() async {
        continuation?.finish()
        continuation = nil
        stream = nil
        await NemotronModelCache.shared.forceUnload()
    }

    /// Loads the model in the background at app launch so the first press doesn't pay
    /// for it. Worth doing because a *cold* load — the file not yet in the page cache,
    /// i.e. the first dictation after a reboot — measured 25s here against 0.7s warm.
    /// Failures are logged and swallowed: `start()` reports them properly when the user
    /// actually presses the key, and there is no UI to show an error to at launch.
    ///
    /// ponytail: pressing the key *during* a cold preload can leave this call's
    /// `scheduleIdleUnload` running under the live dictation, dropping the cache entry
    /// mid-utterance. Harmless — the active `Session` holds its own strong reference to
    /// the `Model`, so it only costs a 0.7s reload on the following press — so no
    /// interlock. Add one if that ever shows up as a real stutter.
    static func preload() async {
        do {
            _ = try await NemotronModelCache.shared.model(path: modelPath)
            await NemotronModelCache.shared.scheduleIdleUnload()
        } catch {
            Log.speech.error("Nemotron preload failed: \(error.localizedDescription)")
        }
    }

    /// Releases the cached model even if no `NemotronEngine` instance is currently
    /// live — the common case at app quit, since the model can be sitting warm from
    /// an earlier dictation with no active `engine` around to call `shutdown()` on.
    static func shutdownModel() async {
        await NemotronModelCache.shared.forceUnload()
    }
}

/// Keeps one loaded `Model` around instead of reopening the GGUF file on every
/// dictation. Matters less than it did for WhisperKit (ggml/Metal load is ~1s, no
/// ANE ahead-of-time compile) but there's still no reason to redo it each press.
private actor NemotronModelCache {
    static let shared = NemotronModelCache()

    /// The loaded model sits at ~716MB resident, which is a lot to hold forever on an
    /// 8GB Mac. A warm reload measured 0.7s, so the wait on the press that follows an
    /// unload is barely perceptible and the window can be short.
    /// ponytail: fixed timeout, no settings UI — revisit if 20s feels wrong.
    private static let idleUnloadDelay: Duration = .seconds(20)

    private var loaded: Model?
    private var loadTask: Task<Model, Error>?
    private var idleUnloadTask: Task<Void, Never>?

    func model(path: String) async throws -> Model {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value }

        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriptionError.modelInstallFailed(
                "Nemotron GGUF not found at \(path). Download "
                    + "nemotron-3.5-asr-streaming-0.6b-Q5_K_M.gguf from "
                    + "huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf "
                    + "and put it there, then retry."
            )
        }

        let task = Task<Model, Error> {
            Log.speech.info("loading Nemotron model…")
            let model = try Model(path: path)
            Log.speech.info("Nemotron model ready (backend: \(model.backend, privacy: .public))")
            return model
        }
        loadTask = task
        defer { loadTask = nil }

        let model = try await task.value
        loaded = model
        return model
    }

    /// Called after every dictation. Frees the model if the idle window elapses without
    /// another `model(path:)` call cancelling this task first.
    func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task {
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled else { return }
            loaded = nil
            Log.speech.info("Nemotron model idle — released")
        }
    }

    /// Frees the model right now, bypassing the idle timer. Used at app quit: the model
    /// must be gone *before* `exit()` runs, not 60 seconds after the process is dead.
    func forceUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        loaded = nil
    }
}
