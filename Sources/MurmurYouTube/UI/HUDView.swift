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
    /// in 2e0ff81 / 95b3e4e / 5d5cd6e came from — change the timing here only.
    static func breathe(time: TimeInterval, phase: Double = 0, amplitude: Double) -> Double {
        amplitude * (0.55 + 0.45 * sin(time * 6.0 + phase))
    }
}

/// How much of the transcript lives next to the wave in the mini-pill. Explored in
/// design-explorations/hud-pill-c4-text-experiments.html; user-pickable so the tradeoff
/// (feedback vs. quiet) is a runtime choice, not a build-time one.
enum HUDStyle: String, CaseIterable, Identifiable {
    /// C4 — just the wave, nothing else. Quietest.
    case waveOnly
    /// D1 — wave + the most recently recognized word.
    case lastWord
    /// D2 — wave + the last few words, pill stretches with them.
    case tail
    /// D4 — wave + last word + elapsed timer. The default.
    case wordTimer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .waveOnly: "Wave only"
        case .lastWord: "Last word"
        case .tail: "Tail of phrase"
        case .wordTimer: "Word + timer"
        }
    }
}

/// Shared by `HUDView` and `HUDPanel`. The panel's window is the pill plus `glowMargin`
/// on every side — sizing the window to the pill alone would clip the glow's blur at the
/// window edge, flattening it into a hard-edged square instead of a halo. The width is
/// fixed at the widest the pill can get (tail with `tailWordCount` words) rather than
/// resized live — the pill is centered in the window, so stretching stays a pure
/// SwiftUI-internal relayout with no window-server involvement.
enum HUDLayout {
    static let pillHeight: CGFloat = 22
    /// Fixed, independent of what's being dictated — the pill must not breathe with the
    /// transcript (user request): text truncates from the head instead.
    static let pillWidth: CGFloat = 150
    static let glowMargin: CGFloat = 36
    static var panelSize: CGSize {
        CGSize(width: pillWidth + glowMargin * 2, height: pillHeight + glowMargin * 2)
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
    var style: HUDStyle { Settings.shared.hudStyle }

    /// Last moment `controller.level` crossed `HUDMotion.minLevel`. Read against
    /// `HUDMotion.speakingHold` to smooth over the natural gaps between words.
    @State private var lastLoudAt: Date = .distantPast
    /// When the current session's clock starts — `.starting`, since that's the moment
    /// the pill appears and the user starts waiting.
    @State private var startedAt: Date?

    var body: some View {
        ZStack {
            glow
            pill
        }
        .frame(width: HUDLayout.panelSize.width, height: HUDLayout.panelSize.height)
        .onChange(of: controller.level) { _, newLevel in
            if newLevel > HUDMotion.minLevel { lastLoudAt = Date() }
        }
        .onChange(of: controller.state.isActive) { _, active in
            startedAt = active ? Date() : nil
        }
    }

    // A separate, larger rounded shape blurred behind the pill — not a `.shadow` on the
    // pill itself. Keeping the glow as its own shape makes the halo's reach (and its own
    // corner radius) tunable independently of the pill.
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFinishing ? Brand.processingGradient : Brand.gradient)
                .opacity(glowOpacity(at: t, release: release))
                .scaleEffect(glowScale(at: t, release: release))
                .frame(width: 110, height: 12)
                .blur(radius: 20)        }
    }

    private var pill: some View {
        HStack(spacing: 5) {
            Waveform(
                level: controller.level,
                isActive: isSpeaking,
                isListening: controller.state.isActive,
                gradient: isFinishing ? Brand.processingGradient : Brand.gradient,
                barCount: 5,
                maxBarHeight: 12
            )
            .frame(width: 23, height: 12)
            .layoutPriority(1)

            text
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(isFinishing ? Brand.processing.opacity(0.95) : Color.primary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.head)
                // Fills the space between the pinned wave and the pinned timer — the text
                // reflows here instead of pushing the siblings around. With nothing to
                // show (wave-only, or word+timer before the first word) it still occupies
                // the space so the wave stays glued to the left edge and the timer to the
                // right, from the very first frame.
                .frame(maxWidth: .infinity)

            if showsTimer {
                timer
            }
        }
        .padding(.horizontal, 10)
        .frame(width: HUDLayout.pillWidth, height: HUDLayout.pillHeight)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
    }

    // MARK: - Style-dependent content

    private var showsTimer: Bool { style == .wordTimer }

    /// What the text slot holds, per style. `.starting`/`.finishing` override the
    /// transcript-derived content — those states have their own story to tell.
    private var text: Text? {
        switch controller.state {
        case .starting:
            return Text("Loading…")
        case .finishing:
            return Text("Transcribing…")
        case .listening:
            let words = controller.transcript
                .split(whereSeparator: \.isWhitespace)
            switch style {
            case .waveOnly:
                return nil
            case .lastWord:
                guard let last = words.last else { return Text("Listening…") }
                return Text(last)
            case .tail, .wordTimer:
                // Full transcript, truncated from the head by SwiftUI's own ellipsis —
                // with a fixed pill width that's exactly the "tail of phrase" effect,
                // and it cuts on rendered width rather than a word count.
                return controller.transcript.isEmpty
                    ? (style == .wordTimer ? nil : Text("Listening…"))
                    : Text(controller.transcript)
            }
        case .error, .idle:
            return nil
        }
    }

    /// Elapsed `m:ss`, ticking on the same `TimelineView` clock the wave rides so the
    /// digits and the bars share one timer (no second 30fps source).
    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
            let elapsed = startedAt.map { timeline.date.timeIntervalSince($0) } ?? 0
            HStack(spacing: 5) {
                Rectangle()
                    .fill(.primary.opacity(0.18))
                    .frame(width: 1, height: 10)
                Text(Self.counterText(elapsed))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.55))
                    .monospacedDigit()
            }
            .fixedSize()
        }
    }

    static func counterText(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
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
    var barCount = 9
    var maxBarHeight: CGFloat = 22

    private var barSpacing: CGFloat { barCount > 6 ? 2 : 3 }

    private var phases: [Double] {
        // Irrational multiplier keeps the offsets from lining up into a visible period.
        (0..<barCount).map { index in
            (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isListening)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
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

        let phase = phases[index] * .pi * 2
        let amplitude = Double(max(HUDMotion.minLevel, level))
        // Wave rides on top of the level so bars still breathe during quiet passages.
        let scaled = CGFloat(HUDMotion.breathe(time: time, phase: phase, amplitude: amplitude))
        return floorHeight + max(0, scaled) * (maxBarHeight - floorHeight)
    }
}
