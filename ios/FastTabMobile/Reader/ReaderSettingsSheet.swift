import SwiftUI

/// Reading appearance settings: size, Tier-A system font, line height,
/// colour scheme and per-appearance background (presets + free colour pick).
/// Writes go straight to `ReaderReadingSettingsStore`, which persists locally
/// and mirrors to iCloud Key-Value Store.
public struct ReaderSettingsSheet: View {
    @ObservedObject var store: ReaderReadingSettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    public init(store: ReaderReadingSettingsStore = .shared) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            List {
                previewSection
                sizeSection
                fontSection
                appearanceSection
                resetSection
            }
            .dsListStyle()
            .navigationTitle("Reading Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("The quick brown fox")
                    .font(store.settings.fontFamily.swiftUIFont(size: 20).weight(.bold))
                Text("Jumps over the lazy dog. Pack my box with five dozen liquor jugs.")
                    .font(store.settings.fontFamily.swiftUIFont(size: CGFloat(store.settings.fontSize)))
                    .lineSpacing(CGFloat((store.settings.lineHeight.value - 1.0)) * CGFloat(store.settings.fontSize))
            }
            .padding(.vertical, DS.Space.sm)
            .listRowBackground(Color(readerHex: effectiveHex))
        }
    }

    private var effectiveHex: String {
        store.settings.effectiveBackgroundHex(systemIsDark: colorScheme == .dark)
    }

    // MARK: - Size + Line Height

    private var sizeSection: some View {
        Section("Size") {
            HStack(spacing: DS.Space.lg) {
                Button {
                    store.setFontSize(store.settings.fontSize - 2)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: DS.IconSize.row, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(DS.Palette.surfaceMuted, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(store.settings.fontSize <= ReaderReadingSettings.fontSizeRange.lowerBound)
                .accessibilityLabel("Smaller text")

                Text("\(store.settings.fontSize) pt")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 52)

                Button {
                    store.setFontSize(store.settings.fontSize + 2)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: DS.IconSize.row, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(DS.Palette.surfaceMuted, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(store.settings.fontSize >= ReaderReadingSettings.fontSizeRange.upperBound)
                .accessibilityLabel("Larger text")

                Spacer()
            }
            .dsListRow()

            Picker("Line spacing", selection: binding(
                get: { store.settings.lineHeight },
                set: { store.setLineHeight($0) }
            )) {
                ForEach(ReaderLineHeight.allCases) { h in
                    Text(h.label).tag(h)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Font

    private var fontSection: some View {
        Section {
            ForEach(ReaderFontFamily.allCases) { family in
                Button {
                    store.setFontFamily(family)
                } label: {
                    HStack {
                        Text("Ag")
                            .font(family.swiftUIFont(size: 22))
                            .frame(width: 40)
                        Text(family.label)
                            .foregroundStyle(.primary)
                        Spacer()
                        if store.settings.fontFamily == family {
                            Image(systemName: "checkmark")
                                .foregroundStyle(DS.Tint.action)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Font")
        } footer: {
            Text("All fonts ship with iOS — no downloads, and safe for commercial use.")
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Mode", selection: binding(
                get: { store.settings.colorScheme },
                set: { store.setColorScheme($0) }
            )) {
                ForEach(ReaderColorScheme.allCases) { scheme in
                    Text(scheme.label).tag(scheme)
                }
            }
            .pickerStyle(.segmented)

            backgroundRow(
                title: "Light background",
                currentHex: store.settings.lightBackgroundHex,
                presets: ReaderReadingSettings.lightPresets,
                set: { store.setLightBackground(hex: $0) }
            )

            backgroundRow(
                title: "Dark background",
                currentHex: store.settings.darkBackgroundHex,
                presets: ReaderReadingSettings.darkPresets,
                set: { store.setDarkBackground(hex: $0) }
            )
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your iPhone's appearance. Reading settings sync across your devices via iCloud.")
        }
    }

    private func backgroundRow(
        title: String,
        currentHex: String,
        presets: [String],
        set: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text(title)
                Spacer()
                // Free pick: any colour, plus the hex for precision.
                ColorPicker("", selection: Binding(
                    get: { Color(readerHex: currentHex) },
                    set: { set($0.toHex() ?? currentHex) }
                ), supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel("Custom \(title.lowercased())")
                Text(currentHex)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DS.Space.sm) {
                ForEach(presets, id: \.self) { hex in
                    Button {
                        set(hex)
                    } label: {
                        Circle()
                            .fill(Color(readerHex: hex))
                            .frame(width: 32, height: 32)
                            .overlay {
                                if ReaderReadingSettings.normalizedHex(currentHex) == hex {
                                    Circle()
                                        .strokeBorder(Color.primary, lineWidth: 2)
                                } else {
                                    Circle()
                                        .strokeBorder(DS.Palette.hairline, lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(hex)")
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                store.resetToDefaults()
            } label: {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
            .disabled(store.settings.isDefault)
        }
    }

    // MARK: - Helpers

    private func binding<T>(get: @escaping () -> T, set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: set)
    }
}

// MARK: - Color → Hex

private extension Color {
    /// Best-effort `#RRGGBB` for an opaque colour (used for the `ColorPicker` bridge).
    func toHex() -> String? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
