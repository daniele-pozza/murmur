import AppKit
import SwiftUI

/// The floating capsule that appears while you hold the key.
///
/// The single most important property here is that this panel **never becomes key**.
/// If it did, the user's text field would lose focus and `TextInjector` would have
/// nothing to insert into. Hence `.nonactivatingPanel` plus `canBecomeKey == false`.
@MainActor
final class HUDPanel: NSPanel {
    private let controller: DictationController

    init(controller: DictationController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(origin: .zero, size: HUDLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        contentView = NSHostingView(rootView: HUDView(controller: controller))
        startSelfHealSync()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Parks the panel just above the Dock, horizontally centered on the screen where the
    /// user is actually dictating. `NSScreen.main` is the screen with the *key window* — and
    /// an accessory app with a non-activating panel rarely has one, so it can be nil. The
    /// screen under the mouse is a better guess than `screens.first` when monitors differ.
    func reposition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else {
            Log.app.error("no screen available to position HUD")
            return
        }
        let visible = screen.visibleFrame
        let size = frame.size
        // The window is `glowMargin` bigger than the pill on every side so the glow has
        // room to blur into — offset by that margin so the *pill*, not the window, still
        // sits 40pt above the Dock.
        setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 40 - HUDLayout.glowMargin
            )
        )
    }

    /// Bumped by every `present()`. `dismiss()`'s fade-out only orders the panel out if no
    /// new session claimed it while that fade was running. The guard this replaced compared
    /// `alphaValue` to 0 — a guess about what the getter returns mid-animation — and losing
    /// that guess ordered the panel out from under a live dictation, which is exactly the
    /// "the mic is recording but there's no pill" case.
    private var generation = 0

    /// Shows the pill, or re-asserts it if it should already be up. Idempotent: called on
    /// every state change *and* twice a second by the self-heal sync timer above.
    ///
    /// Deliberately not animated. A fade-in reads nicer, but it makes "the pill is on
    /// screen" the *outcome of an animation* — one that AppKit can supersede or drop
    /// entirely, leaving the panel shown at a fraction of full alpha, which looks exactly
    /// like no pill at all. That failure mode is invisible from inside the process and only
    /// shows up in real use, i.e. it's untestable here. Setting alpha outright can't fail
    /// and can't be raced: appearing is now one synchronous step. The fade-out below keeps
    /// its animation because the worst it can do on failure is leave the pill up a moment
    /// too long — the harmless direction.
    func present() {
        generation &+= 1

        guard isVisible else {
            reposition()
            alphaValue = 1
            orderFrontRegardless()
            Log.app.info("HUD present: frame=\(NSStringFromRect(self.frame), privacy: .public)")
            return
        }

        // Already up — or fading out from the previous session, in which case this takes it
        // straight back to full rather than letting the fade finish. Re-asserting order and
        // Space membership covers the window server silently dropping a borderless panel
        // from compositing (sleep/wake, Space or fullscreen transitions) without ever
        // clearing `isVisible`. Both are no-ops when the pill really is on screen.
        if alphaValue < 1 { alphaValue = 1 }
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // `orderFrontRegardless` alone is not enough to recover from a lost Space: once the
        // ordering state already says "front", AppKit considers the job done and never asks
        // the window server to re-instruct the window on the *current* Space — observed
        // live as `occlusionState` lacking `.visible` for a whole dictation while repeated
        // re-orders changed nothing. The server-side on-screen check (CGWindowList, not
        // AppKit's `isVisible`) is the ground truth: only when the window is genuinely not
        // being composited do we tear the ordering down with `orderOut` and re-order, which
        // forces the re-instruction. Healthy runs pay one CGWindowList call per tick.
        if !isOnScreenServerSide {
            Log.app.info("HUD ordered but not on screen (window server) — cycling order")
            orderOut(nil)
        }
        orderFrontRegardless()
    }

    /// Whether the window server is actually compositing this window right now. AppKit's
    /// `isVisible` only means "ordered", which a dropped Space keeps claiming forever.
    private var isOnScreenServerSide: Bool {
        guard let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return onScreen.contains { $0[kCGWindowNumber as String] as? Int == windowNumber }
    }

    /// Keeps the pill in step with `controller.state` — and heals it when something
    /// else knocked it out of step.
    ///
    /// State changes already drive `present()`/`dismiss()` (via the controller's
    /// observation), but the window server can drop a borderless panel with no state
    /// change at all to react to (see commit 667e4e4) — the pill goes missing for a
    /// whole utterance while dictation runs fine underneath. Polling makes the pill a
    /// function of the current state instead of the result of an unbroken event chain,
    /// so whatever went wrong heals within half a second. `.common` mode: a
    /// default-mode timer stalls while a menu is open or a window is being dragged.
    /// `present()`/`dismiss()` are both idempotent, hence no extra guards.
    private func startSelfHealSync() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.isActive {
                    self.present()
                } else if self.isVisible {
                    self.dismiss()
                }
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
    }

    func dismiss() {
        let generation = self.generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread. A `present()` for a new dictation
            // can land between the fade starting and this handler firing — dictating fast
            // enough to catch the tail of the previous fade reproduces it.
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.orderOut(nil)
            }
        }
    }
}
