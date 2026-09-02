import SwiftUI

/// Tuning shared by the wave and the glow so their "is this actually speech" and "how
/// loud does it look" logic can't drift apart.
enum HUDMotion {
    /// Below this the mic is picking up room noise, not speech — `AudioCapture.rms(of:)`
    /// already clamps true silence to 0. Also used as the floor amplitude for the wave/glow
    /// pulse so they don't look inert right above this boundary.
    static let minLevel: Float = 0.04
    /// Natural gaps between words dip the smoothed level below `minLevel` for ~150ms even
    /// mid-sentence (`DictationController.level` decays at `(new - level) * 0.35` per
    /// callback). Without a hold, that reads as the wave/glow flickering off and on
    /// throughout ordinary speech. Holding "speaking" true for this long after the last
    /// loud frame bridges those gaps while still dropping out shortly after real silence.
    static let speakingHold: TimeInterval = 0.4
    /// How long the glow takes to fade to nothing once `speakingHold` runs out. Without
    /// this the glow's opacity was a step function of `isSpeaking` — every silence snapped
    /// it straight to 0, which read as a hard cut rather than the halo settling down.
    static let glowRelease: TimeInterval = 0.45

    /// The single owner of the sine "breathe" formula the waveform bars and the glow
    /// pulse both ride: `amplitude * (0.55 + 0.45 * sin(time * 6.0 + phase))`. Callers
    /// hand-rolled this and the constants drifted apart, which is where the sizing bugs
    /// in 2e0ff81 / 95b3e4e / 5d5cd2e came from — change the timing here only.
    static func breathe(time: TimeInterval, phase: Double = 0, amplitude: Double) -> Double {
        amplitude * (0.55 + 0.45 * sin(time * 6.0 + phase))
    }
}

/// Shared by `HUDView` and `HUDPanel`. The panel's window is exactly `pillSize` plus
/// `glowMargin` on every side — sizing the window to the pill alone would clip the glow's
/// blur at the window edge, flattening it into a hard-edged square instead of a halo.
enum HUDLayout {
    static let pillSize = CGSize(width: 200, height: 42)
    static let glowMargin: CGFloat = 50
    static var panelSize: CGSize {
        CGSize(width: pillSize.width + glowMargin * 2, height: pillSize.height + glowMargin * 2)
    }
}

/// Brand palette. Deliberately minimal for the skeleton — this is the surface the real
/// branding pass will replace.
enum Brand {
    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let accentWarm = Color(red: 0.76, green: 0.47, blue: 1.0)
    static let processing = Color(red: 0.95, green: 0.66, blue: 0.32)

    static var gradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentWarm],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Tags the waveform amber while the model is transcribing — the bars themselves go
    /// still once `level` resets to 0, so color is the only cue left that something is
    /// still happening.
    static var processingGradient: LinearGradient {
        LinearGradient(
            colors: [accentWarm, processing],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct HUDView: View {
    @Bindable var controller: DictationController

    /// Last moment `controller.level` crossed `HUDMotion.minLevel`. Read against
    /// `HUDMotion.speakingHold` to smooth over the natural gaps between words.
    @State private var lastLoudAt: Date = .distantPast

    var body: some View {
        ZStack {
            glow
            pill
        }
        .frame(width: HUDLayout.panelSize.width, height: HUDLayout.panelSize.height)
        .onChange(of: controller.level) { _, newLevel in
            if newLevel > HUDMotion.minLevel { lastLoudAt = Date() }
        }
    }

    // A separate, larger rounded shape blurred behind the pill — not a `.shadow` on the
    // pill itself. `.shadow` would silhouette the *pill's* corner radius correctly too, but
    // the panel window only has room for the blur because of the margin below; keeping the
    // glow as its own shape here makes the halo's reach (and its own corner radius) tunable
    // independently of the pill.
    //
    // Driven by the same sine-on-level formula as the waveform bars (phase 0, no per-bar
    // offset) so the halo breathes in step with the wave instead of sitting at a flat
    // opacity — and, like the wave, it's fully silent whenever `isSpeaking` is false.
    private var glow: some View {
        // Paused on `state.isActive` rather than `isSpeaking` — the latter is a
        // time-since-last-loud-frame check, and without a ticking clock while paused it
        // would never re-evaluate past its own hold window if `controller.level` ever
        // settled on a value it was already holding (no `Observable` change to trigger a
        // re-render). Ticking through silence is cheap; `glowOpacity`/`glowPulse` return 0
        // for it regardless.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !controller.state.isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let release = glowRelease(at: timeline.date)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isFinishing ? Brand.processingGradient : Brand.gradient)
                .opacity(glowOpacity(at: t, release: release))
                .scaleEffect(glowScale(at: t, release: release))
                .frame(width: HUDLayout.pillSize.width - 10, height: HUDLayout.pillSize.height - 10)
                .blur(radius: 28)
        }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Waveform(
                level: controller.level,
                isActive: isSpeaking,
                isListening: controller.state.isActive,
                gradient: isFinishing ? Brand.processingGradient : Brand.gradient
            )
            .frame(width: 19, height: 8)
            // Centered in its own quarter of the pill's content width (180pt / 4 = 45pt),
            // not stretched to fill it.
            .frame(width: 45)
            // Fixed-size sibling in a tight HStack — without priority, a long
            // unbreakable run of text can still squeeze this narrower than its frame.
            .layoutPriority(1)

            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(isError ? Color.red.opacity(0.9) : .primary.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.12), value: controller.transcript)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: HUDLayout.pillSize.width, height: HUDLayout.pillSize.height)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        }
    }

    private var isFinishing: Bool {
        if case .finishing = controller.state { return true }
        return false
    }

    private var isSpeaking: Bool {
        controller.state.isActive && Date().timeIntervalSince(lastLoudAt) < HUDMotion.speakingHold
    }

    /// 1 while within `speakingHold` of the last loud frame, easing down to 0 over
    /// `glowRelease` afterward — the glow's fade-out rather than a hard on/off switch.
    private func glowRelease(at now: Date) -> Double {
        guard controller.state.isActive else { return 0 }
        let sinceLoud = now.timeIntervalSince(lastLoudAt)
        guard sinceLoud > HUDMotion.speakingHold else { return 1 }
        let intoRelease = sinceLoud - HUDMotion.speakingHold
        guard intoRelease < HUDMotion.glowRelease else { return 0 }
        return 1 - intoRelease / HUDMotion.glowRelease
    }

    private func glowPulse(at time: TimeInterval, release: Double) -> CGFloat {
        guard release > 0 else { return 0 }
        return CGFloat(HUDMotion.breathe(
            time: time,
            amplitude: Double(max(HUDMotion.minLevel, controller.level)) * release
        ))
    }

    private func glowOpacity(at time: TimeInterval, release: Double) -> Double {
        guard release > 0 else { return 0 }
        return (0.35 + Double(glowPulse(at: time, release: release)) * 0.5) * release
    }

    private func glowScale(at time: TimeInterval, release: Double) -> CGFloat {
        1.0 + glowPulse(at: time, release: release) * 0.12
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    private var label: String {
        switch controller.state {
        // `.starting` spans the mic-permission check and the model load, and capture
        // hasn't begun yet — so this is the honest place for "loading", and it clears
        // itself the moment the state advances. Usually a ~0.7s flash off a warm model;
        // the ~25s cold load after a reboot is the case it's actually there for.
        case .starting: "Loading speech model…"
        case .listening: controller.transcript.isEmpty ? "Listening…" : controller.transcript
        // Nothing more streams in after the final chunk lands, so say what's happening
        // rather than leaving an empty pill while the formatter runs.
        case .finishing: controller.transcript.isEmpty ? "Transcribing…" : controller.transcript
        case .error(let message): message
        case .idle: ""
        }
    }
}

/// Level-reactive bars. Each bar gets a fixed phase offset so the group ripples rather
/// than pumping in unison.
private struct Waveform: View {
    let level: Float
    /// Whether to draw a rippling wave (true) or hold at `floorHeight` (false) — driven by
    /// `HUDView.isSpeaking`'s hold window, not the raw level.
    let isActive: Bool
    /// Whether dictation is running at all. Keeps the `TimelineView` ticking through pauses
    /// between words so `isActive`'s hold window gets re-evaluated even if `level` settles
    /// on a repeated value with no `Observable` change to trigger a re-render.
    let isListening: Bool
    var gradient: LinearGradient = Brand.gradient

    // 9 bars * 3pt + 8 gaps * 2pt = 43pt — fits inside the 45pt slot HUDView gives this
    // view. The old 12-bar / 3pt-gap combination summed to 69pt and spilled past both
    // edges of that slot, since a fixed `.frame` doesn't clip a wider HStack by default.
    private static let barCount = 9
    private static let barSpacing: CGFloat = 2
    private static let phases: [Double] = (0..<barCount).map { index in
        // Irrational multiplier keeps the offsets from lining up into a visible period.
        (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isListening)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(gradient)
                        .frame(width: 3, height: height(for: index, at: t))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
    }

    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        let floorHeight: CGFloat = 2
        guard isActive else { return floorHeight }

        let phase = Self.phases[index] * .pi * 2
        let amplitude = Double(max(HUDMotion.minLevel, level))
        // Wave rides on top of the level so bars still breathe during quiet passages.
        let scaled = CGFloat(HUDMotion.breathe(time: time, phase: phase, amplitude: amplitude))
        // Half of the pre-halving peak (23), matching the bars' halved frame.
        return floorHeight + max(0, scaled) * 11
    }
}
