import SwiftUI

/// The Settings window (⌘,). Three tabs: General, Buttons, Scroll.
struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        TabView {
            generalTab.tabItem  { Label("General", systemImage: "gearshape") }
            buttonsTab.tabItem  { Label("Buttons", systemImage: "computermouse") }
            scrollTab.tabItem   { Label("Scroll", systemImage: "scroll") }
            gesturesTab.tabItem { Label("Gestures", systemImage: "hand.draw") }
        }
        .frame(width: 480, height: 360)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Toggle("Enable QmouseFix", isOn: $store.config.enabled)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    LoginItem.setEnabled(newValue)
                    launchAtLogin = LoginItem.isEnabled // resync to the real status
                }
            LabeledContent("Accessibility") {
                if AccessibilityPermission.isTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Grant…") { AccessibilityPermission.openSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var buttonsTab: some View {
        ButtonMappingsView()
    }

    private var scrollTab: some View {
        Form {
            Picker("Scroll style", selection: $store.config.scrollMode) {
                ForEach(ScrollMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if store.config.scrollMode == .smooth {
                VStack(alignment: .leading) {
                    Text("Scroll speed: \(String(format: "%.1f×", store.config.scrollSpeed))")
                    Slider(value: $store.config.scrollSpeed, in: 0.2...1.5, step: 0.1) {
                        Text("Scroll speed")
                    } minimumValueLabel: { Text("Slow").font(.caption) }
                      maximumValueLabel: { Text("Fast").font(.caption) }
                }
            }
            if store.config.scrollMode == .smoothStep {
                Stepper(value: $store.config.scrollLines, in: 1...10) {
                    Text("Lines per notch: \(store.config.scrollLines)")
                }
            }
            Toggle("Reverse scroll direction", isOn: $store.config.reverseScroll)
            Text("Standard = instant wheel (no animation). Smooth = trackpad-style momentum. Smooth-step = Windows-browser feel: each notch eases a fixed number of lines with no coast. Applies to a physical mouse wheel only — trackpad scrolling is left untouched.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var gesturesTab: some View {
        Form {
            Picker("Drag to switch Spaces", selection: $store.config.spaceDragButton) {
                Text("Off").tag(0)
                ForEach(3...9, id: \.self) { Text("Button \($0)").tag($0) }
            }
            if store.config.spaceDragButton != 0 {
                VStack(alignment: .leading) {
                    Text("Drag distance per Space: \(Int(store.config.spaceDragThreshold)) px")
                    Slider(value: $store.config.spaceDragThreshold, in: 100...400, step: 10)
                }
                Toggle("Reverse drag direction", isOn: $store.config.spaceDragReverse)
            }
            Text("Hold the chosen button and drag left/right to switch Spaces — one jump per drag distance. (macOS 26+ only supports discrete jumps, not a smooth follow-finger animation.)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
