import SwiftUI
import EinkCore
import EinkMac

/// First-run guide: explain the effect, preview it, and opt in to extras before anything changes.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let finish: (_ turnOn: Bool) -> Void
    @State private var dim = false
    @State private var brightness = 50.0
    @State private var hideDock = false
    @AppStorage("shortcut") private var shortcut = Shortcut.presets[0].id
    private var shortcutSymbol: String? { Shortcut.presets.first { $0.id == shortcut }?.symbol }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 40, weight: .light))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to E-Ink Mode").font(.title2.bold())
                    Text("Beta \(EinkEnvironment.version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            step(1, "What it does") {
                Text("E-Ink Mode turns your screen grayscale, like an e-reader, so it feels calmer and less distracting. Your apps, files, and settings are not changed.")
                Text("Turning it off — or quitting — puts your display back exactly as it was.").foregroundStyle(.secondary)
            }
            step(2, "Try it first") {
                HStack(spacing: 12) {
                    if let left = model.previewRemaining {
                        Button("End Preview") { model.endPreview() }
                        Text("Back to color in \(left)s…").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Button("Preview Grayscale for 10 Seconds") { model.startPreview() }
                            .disabled(model.status == nil || model.active || model.needsRecovery)
                    }
                }
                Text("The preview changes only grayscale and ends on its own.").font(.caption).foregroundStyle(.secondary)
            }
            step(3, "Optional extras — off unless you choose them") {
                Toggle(isOn: $dim) {
                    HStack {
                        Text("Also dim the screen to")
                        Slider(value: $brightness, in: 5...100, step: 5).frame(width: 110).disabled(!dim)
                        Text("\(Int(brightness))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                }.disabled(!model.hasBrightness)
                if !model.hasBrightness { Text("This display doesn't support brightness control.").font(.caption).foregroundStyle(.secondary) }
                Toggle("Also auto-hide the Dock", isOn: $hideDock)
                Text("Your current brightness and Dock setting are saved and put back when you turn it off. You can change these any time in Customize Appearance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            step(4, "Where to find it") {
                Text("Look for ○ at the top-right of your screen, in the menu bar. It fills in (●) while your screen is grayscale. Click it for the menu.")
                Toggle("Click the icon to switch on and off instead (right-click for the menu)", isOn: $model.clickToFlip)
                if let shortcutSymbol { Text("Or press \(shortcutSymbol) from any app.").foregroundStyle(.secondary) }
                Text("Studying? Choose Start Focus in the menu: grayscale focus sessions with color breaks in between.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Not Now") { save(); finish(false) }
                Spacer()
                Button("Turn On E-Ink Mode") { save(); finish(true) }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
                    .disabled(model.status == nil || model.needsRecovery || model.previewRemaining != nil)
            }
        }
        .padding(26)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            guard let config = model.status?.configuration else { return }
            dim = config.brightness != nil; hideDock = config.hideDock
            brightness = (config.brightness ?? 0.5) * 100
        }
    }
    private func save() {
        model.endPreview()
        let dim = dim && model.hasBrightness, level = brightness / 100, hideDock = hideDock
        model.change { $0.grayscale = true; $0.brightness = dim ? level : nil; $0.hideDock = hideDock }
    }
    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.callout.bold()).frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}
