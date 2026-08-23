import SwiftUI

/// Settings — hotkey and model, per the brief. Opens on ⌘, via the standard `Settings` scene,
/// so the system wires up the menu item and the shortcut.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            VStack(alignment: .leading, spacing: DS.Space.wide) {
                panel(label: "Push to talk") {
                    HStack(spacing: DS.Space.snug) {
                        ForEach(PushToTalkKey.allCases, id: \.self) { key in
                            TransportKey(
                                title: key.displayName,
                                isEngaged: settings.pushToTalkKey == key,
                                engagedColor: DS.Color.ink
                            ) {
                                settings.pushToTalkKey = key
                                controller.reloadHotkey()
                            }
                            .background {
                                if settings.pushToTalkKey == key {
                                    RoundedRectangle(cornerRadius: DS.Radius.control)
                                        .fill(DS.Color.selection)
                                }
                            }
                        }
                    }
                    note("Press this key to start dictating, press it again to stop. The "
                        + "window's Record button works regardless of what's focused.")
                }

                panel(label: "Cleanup") {
                    Toggle(isOn: $settings.cleanupEnabled) {
                        Silkscreen(text: "Clean up transcripts")
                    }
                    .toggleStyle(.switch)
                    note("Strips fillers, fixes spacing and punctuation.")
                }

                Spacer()
            }
            .padding(DS.Space.panel)
        }
        .frame(width: 520, height: 460)
    }

    private func panel<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Silkscreen(text: label, large: true)
            content()
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrushedPanel())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
