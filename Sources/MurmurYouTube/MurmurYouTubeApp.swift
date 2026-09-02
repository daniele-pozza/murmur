import AppKit
import Darwin
import SwiftUI

@main
struct MurmurYouTubeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window("Murmur", id: "main") {
            MainWindow(controller: delegate.controller)
        }
        .defaultSize(width: 860, height: 620)
        // Menu-bar app: launching shouldn't put a window on screen. Open it from the menu
        // bar item when you actually want it.
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Fully qualified: this app has its own `Settings` type, which otherwise shadows
        // SwiftUI's settings scene.
        SwiftUI.Settings {
            SettingsWindow(controller: delegate.controller)
        }

        // Secondary now: status and the hotkey while you're working in another app.
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.state.isActive ? "waveform.circle.fill" : "waveform")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private var hud: HUDPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only, like Handy: no Dock icon or Cmd-Tab entry. The main window still
        // opens (from the menu bar item) when you actually want it. The HUD is a
        // non-activating panel regardless, so dictating into another app never steals focus.
        NSApp.setActivationPolicy(.accessory)

        hud = HUDPanel(controller: controller)

        if !controller.activate() {
            Permissions.promptForAccessibility()
            // The tap can only be created once the user grants Accessibility, and there's
            // no notification for that — poll until it takes.
            retryActivation()
        }

        observeState()
        Log.app.info("Murmur ready — press \(Settings.shared.pushToTalkKey.displayName) to dictate")

        // Detached, so a cold model load (~25s the first time after a reboot) can't hold
        // up the main actor. It arms its own idle-unload timer, so a launch nobody
        // dictates after doesn't leave 716MB parked forever.
        Task.detached(priority: .utility) { await NemotronEngine.preload() }
    }

    /// `.terminateLater` + a manual `_exit` instead of the default `.terminateNow`: the
    /// model has to be released *before* the process reaches `exit()`, not during it.
    /// ggml's own atexit cleanup frees its Metal device on the way out, and it aborts if
    /// that device is still resident when atexit runs (SIGSEGV in
    /// `ggml_metal_rsets_free`, reliably reproducible on every quit before this fix).
    /// Releasing the model ourselves first, then skipping straight to `_exit` — which,
    /// unlike `exit`, never runs atexit handlers — avoids ggml's cleanup path entirely.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await controller.shutdown()
            _exit(0)
        }
        return .terminateLater
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                Log.app.info("HUD state → \(String(describing: self.controller.state), privacy: .public)")
                self.syncHUD()
                self.observeState()
            }
        }
    }

    private func syncHUD() {
        guard let hud else { return }
        if controller.state.isActive {
            hud.present()
        } else if hud.isVisible {
            hud.dismiss()
        }
    }

    private func retryActivation() {
        Task { @MainActor in
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            controller.activate()
            Log.app.info("Accessibility granted — hotkey armed")
        }
    }
}

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Press \(settings.pushToTalkKey.displayName) to dictate")

        Divider()

        Picker("Push-to-talk key", selection: Binding(
            get: { settings.pushToTalkKey },
            set: { key in
                settings.pushToTalkKey = key
                controller.reloadHotkey()
            }
        )) {
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }

        Toggle("Clean up text", isOn: $settings.cleanupEnabled)
        Toggle("Sound", isOn: $settings.soundEnabled)

        Divider()

        if !Permissions.hasAccessibility {
            Button("Grant Accessibility…") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasMicrophone {
            Button("Grant Microphone…") { Permissions.openMicrophoneSettings() }
        }

        // The window no longer opens at launch, so this is the only way back to it.
        Button("Open Murmur…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
