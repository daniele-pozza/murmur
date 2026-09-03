import AppKit
import SwiftUI

/// The floating capsule that appears while you hold the key.
///
/// This class *owns* an NSPanel rather than being one, because the panel can need to be
/// thrown away and rebuilt: the window server sometimes refuses to composite a
/// `canJoinAllSpaces` panel on the current Space (observed reliably over native-fullscreen
/// app windows). `orderOut`/`orderFront` cycling heals it on ordinary Spaces but not there —
/// the panel stays pinned to its original Space forever while AppKit's `isVisible` keeps
/// claiming it is shown. A freshly created panel always joins the current Space, so after
/// three failed heal cycles we rebuild the panel outright.
///
/// The single most important property is unchanged: the panel **never becomes key**, or the
/// user's text field would lose focus and `TextInjector` would have nothing to insert into.
@MainActor
final class HUDPanel {
    private let controller: DictationController

    private var panel: NSPanel!
    var isVisible: Bool { panel.isVisible }

    init(controller: DictationController) {
        self.controller = controller
        panel = Self.makePanel(controller: controller)
        startSelfHealSync()
    }

    private static func makePanel(controller: DictationController) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: HUDLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: HUDView(controller: controller))
        return panel
    }

    /// Parks the panel just above the Dock, horizontally centered on the screen where the
    /// user is actually dictating. `NSScreen.main` is the screen with the *key window* — and
    /// an accessory app with a non-activating panel rarely has one, so it can be nil. The
    /// screen under the mouse is a better guess than `screens.first` when monitors differ.
    private func reposition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else {
            Log.app.error("no screen available to position HUD")
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // The window is `glowMargin` bigger than the pill on every side so the glow has
        // room to blur into — offset by that margin so the *pill*, not the window, still
        // sits 40pt above the Dock.
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 40 - HUDLayout.glowMargin
            )
        )
    }

    /// Bumped by every `present()`. `dismiss()`'s fade-out only orders the panel out if no
    /// new session claimed it while that fade was running.
    private var generation = 0

    /// Consecutive `present()` ticks where the panel is ordered but the window server
    /// still isn't compositing it. Three in a row (~1.5s of a live dictation) triggers a
    /// panel rebuild — the heal that cycling alone can't do on fullscreen Spaces.
    private var failedCycles = 0

    /// Shows the pill, or re-asserts it if it should already be up. Idempotent: called on
    /// every state change *and* twice a second by the self-heal sync timer. Deliberately
    /// not animated: appearing is one synchronous `alphaValue = 1` step that can't fail or
    /// be raced (fade-in failure modes look exactly like this bug).
    func present() {
        generation &+= 1

        guard panel.isVisible else {
            reposition()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            Log.app.info("HUD present: frame=\(NSStringFromRect(self.panel.frame), privacy: .public)")
            return
        }

        // Already up — or fading out from the previous session; take it back to full.
        if panel.alphaValue < 1 { panel.alphaValue = 1 }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // AppKit's `isVisible` only means "ordered"; the window server can keep the panel
        // off the current Space without ever clearing it (Space/fullscreen transitions).
        // The server-side check (CGWindowList, not AppKit) is ground truth. Cycling the
        // order heals ordinary drops; when it fails three ticks in a row the panel is
        // pinned to a dead Space (fullscreen apps) and only a rebuild re-joins it.
        if !isOnScreenServerSide {
            failedCycles += 1
            if failedCycles >= 3 {
                Log.app.info("HUD uncomposited \(self.failedCycles) ticks — rebuilding panel")
                failedCycles = 0
                panel.orderOut(nil)
                panel = Self.makePanel(controller: controller)
                reposition()
                panel.alphaValue = 1
            } else {
                panel.orderOut(nil)
            }
        } else {
            failedCycles = 0
        }
        panel.orderFrontRegardless()
    }

    /// Whether the window server is actually compositing this window right now.
    private var isOnScreenServerSide: Bool {
        guard let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return onScreen.contains { $0[kCGWindowNumber as String] as? Int == panel.windowNumber }
    }

    /// Keeps the pill in step with `controller.state`. State changes already drive
    /// `present()`/`dismiss()` (via the app's observation), but the window server can
    /// drop the panel with no state change to react to — polling makes the pill a
    /// function of the current state instead of an unbroken event chain. `.common` mode:
    /// a default-mode timer stalls while a menu is open or a window is being dragged.
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
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread. A `present()` for a new dictation
            // can land between the fade starting and this handler firing.
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}
