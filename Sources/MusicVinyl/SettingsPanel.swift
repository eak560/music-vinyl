import SwiftUI

/// Slides up like the playlist browser: the settings that need more than a
/// checkbox — the disc's look and how fast it turns — alongside the toggles.
struct SettingsPanel: View {
    @EnvironmentObject private var model: NowPlayingModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))

            // ImageRenderer will not materialise ScrollView content, so the
            // dev render flag lays the sections out flat instead.
            if ProcessInfo.processInfo.environment["VINYL_NO_SCROLL"] != nil {
                sections
            } else {
                ScrollView { sections }
            }
        }
        .foregroundStyle(.white)
        .background(.black.opacity(0.55))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            discStyleSection
            speedSection
            togglesSection
        }
        .padding(14)
    }

    private var header: some View {
        HStack {
            Text("Turntable").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var discStyleSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Disc")
            Picker("", selection: $model.discStyle) {
                ForEach(DiscStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle("Speed")
                Spacer()
                Text(String(format: "%.1f RPM", model.rpm))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .opacity(0.7)
            }
            Slider(value: $model.rpm, in: 5...120)
                .controlSize(.small)
            HStack(spacing: 6) {
                ForEach([33.3333, 45.0, 78.0], id: \.self) { preset in
                    Button(preset == 33.3333 ? "33⅓" : String(format: "%.0f", preset)) {
                        model.rpm = preset
                    }
                    .buttonStyle(PresetStyle(active: abs(model.rpm - preset) < 0.05))
                }
                Spacer()
            }
        }
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Window")
            Toggle("Always on Top", isOn: $model.alwaysOnTop)
            Toggle("Show Track Info", isOn: $model.showTrackInfo)
            Toggle("Glass Background", isOn: $model.glassBackground)
            Toggle("Look Up Artwork Online", isOn: $model.onlineArtwork)
            Toggle("Use Media Keys", isOn: $model.interceptMediaKeys)
            if model.mediaKeysNeedPermission {
                Button("Grant Accessibility…") { model.syncMediaKeyTap(promptIfNeeded: true) }
                    .buttonStyle(PresetStyle(active: true))
                Text("The ⏭ key needs Accessibility to reach the app.")
                    .font(.system(size: 10))
                    .opacity(0.55)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 12))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .opacity(0.5)
    }
}

private struct PresetStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(.white.opacity(active ? 0.22 : 0.08))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(active ? 0.35 : 0.0)))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
