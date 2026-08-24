import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture with on-the-fly conversion to whatever format the speech engine wants.
///
/// The tap runs on a real-time audio thread, so everything it touches lives behind
/// `nonisolated(unsafe)` and is only ever mutated from that one thread.
///
/// The engine is deliberately **not** reused across sessions. A long-lived `AVAudioEngine`
/// accumulates Core Audio/HAL state on macOS — sample-rate drift, configuration changes,
/// buffer underruns — that makes each successive recording worse and eventually wedges the
/// input entirely (the classic "dictation gets worse every time, then the mic goes dead"
/// report). A fresh engine per session sidesteps that, the same fix FluidVoice applies
/// (its `AudioEngineRetirementDrain`) and Handy does too (a fresh cpal stream per
/// recording). Because `-[AVAudioEngine dealloc]` can block on AVAudioIOUnit's internal
/// queue, the old engine is released on a dedicated serial queue rather than the caller's
/// thread, and `start()` drains that queue first so teardown never overlaps construction.
final class AudioCapture: @unchecked Sendable {
    private nonisolated(unsafe) var engine: AVAudioEngine?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private nonisolated(unsafe) var isRunning = false
    private nonisolated(unsafe) var tapInstalled = false

    /// Called on the audio thread with each converted buffer.
    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    /// Called on the audio thread with a 0…1 RMS level, for the HUD waveform.
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?
    /// Called when the engine's configuration changes mid-session (input device switched,
    /// sample rate changed). The controller tears the session down — capture is no longer
    /// trustworthy. Invoked on the notification's posting thread; the caller hops to its
    /// own actor.
    private nonisolated(unsafe) var onConfigurationChange: (@Sendable () -> Void)?

    /// Serializes `AVAudioEngine` deallocation off the caller's thread. See the type doc.
    private let retirementQueue = DispatchQueue(
        label: "ai.pivotstudio.murmur.audio-engine-retirement",
        qos: .utility
    )

    /// NotificationCenter token for the current engine's configuration-change observer.
    private nonisolated(unsafe) var configObserver: NSObjectProtocol?

    /// The default input device's nominal sample rate at capture start, restored on stop
    /// (see `defaultInputSampleRate()`).
    private nonisolated(unsafe) var originalSampleRate: Double?
    /// The device that rate was snapshotted from, so `stop()` restores it only if that
    /// device is still the default — restoring a *new* default (device switched mid-session)
    /// to an old rate would degrade it for every other app.
    private nonisolated(unsafe) var originalDeviceID: AudioDeviceID?

    /// When this session's engine started. The config-change observer ignores notifications
    /// within a short window after `start()`, because the engine itself posts
    /// `.AVAudioEngineConfigurationChange` while establishing IO on the input device —
    /// reacting to that would tear down a session that only just began listening.
    private nonisolated(unsafe) var startedAt: Date?

    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void = {}
    ) throws {
        guard !isRunning else { return }

        // Barrier: finish releasing whatever engine the previous session retired before
        // constructing a new one, so teardown and construction never overlap on Core Audio.
        retirementQueue.sync {}

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onConfigurationChange = onConfigurationChange
        self.outputFormat = outputFormat

        // Snapshot the device's rate before the engine touches it, so `stop()` can restore
        // it if `AVAudioEngine` reconfigures the device on start.
        originalDeviceID = Self.defaultInputDeviceID()
        originalSampleRate = Self.defaultInputSampleRate()

        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let nativeFormat = try readyInputFormat(of: input)

        converter = nativeFormat == outputFormat
            ? nil
            : AVAudioConverter(from: nativeFormat, to: outputFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: nativeFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        tapInstalled = true

        // Arm the guard window only once the engine is about to start. `readyInputFormat`
        // can block up to a second while the HAL settles after wake-from-sleep; stamping
        // `startedAt` any earlier would let the engine's own startup reconfiguration slip
        // past the window and tear the session down the moment it begins. The notification
        // the engine posts while establishing IO lands well inside the second we bracket.
        installConfigObserver(for: engine)
        startedAt = Date()

        engine.prepare()
        try startEngine(engine)
        isRunning = true
        Log.audio.info("capture started — native \(nativeFormat.sampleRate)Hz → engine \(outputFormat.sampleRate)Hz")
    }

    func stop() {
        guard engine != nil else { return }

        removeConfigObserver()

        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        restoreOriginalSampleRate()
        startedAt = nil
        tapInstalled = false
        isRunning = false
        converter = nil
        onBuffer = nil
        onLevel = nil
        onConfigurationChange = nil
        outputFormat = nil

        // Release the engine off this thread: `-[AVAudioEngine dealloc]` can block on
        // AVAudioIOUnit's internal queue, and `start()`/`stop()` run on the main actor.
        // The token owns the last strong reference, so the `@Sendable` block captures a
        // Sendable box rather than the non-Sendable engine itself.
        let token = EngineRetirementToken(engine)
        self.engine = nil
        retirementQueue.async { token.release() }
        Log.audio.info("capture stopped")
    }

    // MARK: - Engine setup

    /// Blocks briefly for the HAL to settle after a wake-from-sleep, when the input node
    /// can transiently report a 0 Hz / 0 ch format that would otherwise make the tap
    /// install or the converter fail.
    private func readyInputFormat(of input: AVAudioInputNode) throws -> AVAudioFormat {
        var format = input.inputFormat(forBus: 0)
        var attempts = 0
        while (format.sampleRate == 0 || format.channelCount == 0) && attempts < 10 {
            attempts += 1
            Thread.sleep(forTimeInterval: 0.1)
            format = input.inputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TranscriptionError.noAudioFormat
        }
        return format
    }

    /// `engine.start()` is transiently flaky right after a route change or device swap;
    /// retry a couple of times before giving up.
    private func startEngine(_ engine: AVAudioEngine) throws {
        var attempts = 0
        while true {
            do {
                try engine.start()
                return
            } catch {
                attempts += 1
                guard attempts < 3 else { throw error }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    // MARK: - Configuration change

    private func installConfigObserver(for engine: AVAudioEngine) {
        // `queue: nil` is load-bearing: AVAudioEngine posts this notification from its own
        // internal serial queue, and NotificationCenter blocks a post until observers on
        // that queue finish. A `.main`-queue observer could therefore deadlock while the
        // main thread is itself blocked on the engine (e.g. inside `stop()`). The handler
        // only forwards; the controller decides what to do, on its own actor.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // See `startedAt` — the engine's own start-up reconfiguration is not a reason
            // to drop the session, so changes during the first second are ignored.
            guard let self, let started = self.startedAt,
                  Date().timeIntervalSince(started) > 1.0 else { return }
            self.onConfigurationChange?()
        }
    }

    private func removeConfigObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    // MARK: - Device sample-rate restore

    /// `AVAudioEngine` can change the default input device's nominal sample rate when it
    /// starts and does not always put it back on stop, leaving the mic (and other apps
    /// recording through it) sounding off until the rate is corrected. Snapshot it before
    /// capture and restore it after. Handy avoids this by opening a fresh cpal stream at the
    /// device's native rate; we fix it explicitly instead.
    private static func defaultInputSampleRate() -> Double? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private func restoreOriginalSampleRate() {
        defer {
            originalSampleRate = nil
            originalDeviceID = nil
        }
        // Only restore if the device we snapshotted is still the default input. If the user
        // switched devices mid-session, the new one's rate is its own business.
        guard let original = originalSampleRate,
              let originalID = originalDeviceID,
              let deviceID = Self.defaultInputDeviceID(),
              deviceID == originalID else { return }
        var rate = original
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate
        )
        Log.audio.info("restored input sample rate to \(rate)Hz (status \(status))")
    }

    // MARK: - Audio thread

    private func handle(_ buffer: AVAudioPCMBuffer) {
        onLevel?(Self.rms(of: buffer))

        guard let outputFormat else { return }

        // AVAudioEngine reuses the tap's buffer as soon as this returns, so the engine
        // must never see it directly — copy when no conversion would otherwise allocate.
        guard let converter else {
            if let copy = Self.copy(buffer) {
                onBuffer?(AudioChunk(buffer: copy))
            }
            return
        }

        // Output frame count scales with the sample-rate ratio; round up so we never clip.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let input = buffer
        let consumed = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        onBuffer?(AudioChunk(buffer: converted))
    }

    /// Deep-copies a tap buffer into storage we own.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }

        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }

        return copy
    }

    /// One-shot flag. Only touched from the audio thread inside a synchronous call.
    private final class Latch: @unchecked Sendable {
        private var fired = false
        /// - Returns: the value *before* this call, then latches to `true`.
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }

    /// Owns the final strong reference to an `AVAudioEngine` being released off-thread.
    /// Wrapping the engine lets the retirement block capture a `Sendable` box instead of
    /// the non-Sendable `AVAudioEngine` itself.
    private final class EngineRetirementToken: @unchecked Sendable {
        private var engine: AVAudioEngine?
        init(_ engine: AVAudioEngine?) { self.engine = engine }
        func release() { self.engine = nil }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()

        // Map roughly -50…0 dBFS onto 0…1 so quiet speech still moves the meter.
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}
