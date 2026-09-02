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
        let model = try await NemotronModelCache.shared.acquire(path: Self.modelPath)
        do {
            let session = try model.session()
            let stream = try session.stream()
            self.stream = stream
        } catch {
            // Don't leak the acquired refcount — the cache would hold the model warm
            // forever (nobody else will release it for us).
            await NemotronModelCache.shared.release()
            throw error
        }

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
            Task { await NemotronModelCache.shared.release() }
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
        await NemotronModelCache.shared.release()
    }

    /// Loads the model in the background at app launch so the first press doesn't pay
    /// for it. Worth doing because a *cold* load — the file not yet in the page cache,
    /// i.e. the first dictation after a reboot — measured 25s here against 0.7s warm.
    /// Failures are logged and swallowed: `start()` reports them properly when the user
    /// actually presses the key, and there is no UI to show an error to at launch.
    ///
    /// The acquire/release pair interlocks with a dictation that starts mid-preload:
    /// the real `acquire()` takes its own refcount, so this `release()` leaves the
    /// count above zero and the idle unload never fires under the live session.
    static func preload() async {
        do {
            _ = try await NemotronModelCache.shared.acquire(path: modelPath)
            await NemotronModelCache.shared.release()
        } catch {
            Log.speech.error("Nemotron preload failed: \(error.localizedDescription)")
        }
    }

    /// Releases the cached model even if no `NemotronEngine` instance is currently
    /// live — the common case at app quit, since the model can be sitting warm from
    /// an earlier dictation with no active `engine` around to call `shutdown()` on.
    static func shutdownModel() async {
        await NemotronModelCache.shared.unloadNow()
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

    /// unloaded → loading → ready(model, refcount:). There is no `unloading` case:
    /// unload is synchronous on the actor, so it never exists between messages for
    /// another caller to observe. `ready(_, refcount: 0)` means "warm, idle timer
    /// running" — the model is dropped only when the timer fires with the count
    /// still at zero, or by `unloadNow()` at process exit.
    private enum State {
        case unloaded
        case loading(Task<Model, Error>)
        case ready(model: Model, refcount: Int)
    }

    private var state = State.unloaded
    private var idleTask: Task<Void, Never>?

    /// Takes one refcount and returns the model. Concurrent callers share one load
    /// task; every caller that awaited it promotes the count exactly once.
    func acquire(path: String) async throws -> Model {
        idleTask?.cancel()
        idleTask = nil

        switch state {
        case .ready(let model, let refcount):
            state = .ready(model: model, refcount: refcount + 1)
            return model
        case .loading(let task):
            let model = try await task.value
            promote(model)
            return model
        case .unloaded:
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
            state = .loading(task)
            do {
                let model = try await task.value
                promote(model)
                return model
            } catch {
                // Back to .unloaded, or a failed load poisons the cache: every later
                // acquire() would re-throw this stale error instead of retrying.
                if case .loading(let t) = state, t == task { state = .unloaded }
                throw error
            }
        }
    }

    /// The one place a resolved load task turns into cache state. Every acquirer
    /// awaiting the same task runs this after it resumes; only the first still sees
    /// `.loading`. `.unloaded` means `unloadNow()` won the race — the caller keeps
    /// the model alive via its own `Session` and its later `release()` is a no-op.
    private func promote(_ model: Model) {
        switch state {
        case .loading:
            state = .ready(model: model, refcount: 1)
        case .ready(_, let refcount):
            state = .ready(model: model, refcount: refcount + 1)
        case .unloaded:
            break
        }
    }

    /// Drops one refcount. At zero the model stays warm until the idle timer fires
    /// without a new `acquire()` cancelling it first.
    func release() {
        guard case .ready(let model, let refcount) = state else { return }
        state = .ready(model: model, refcount: max(refcount - 1, 0))
        guard refcount <= 1 else { return }
        idleTask = Task {
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled else { return }
            guard case .ready(_, 0) = state else { return }
            state = .unloaded
            Log.speech.info("Nemotron model idle — released")
        }
    }

    /// Frees the model right now, bypassing the idle timer. Used at app quit: the model
    /// must be gone *before* `exit()` runs, not 60 seconds after the process is dead.
    func unloadNow() {
        idleTask?.cancel()
        idleTask = nil
        if case .loading(let task) = state { task.cancel() }
        state = .unloaded
    }
}
