import SwiftUI

/// Native application Settings; the reader and Settings share canonical AppStorage keys.
struct NotesAppearanceSettings: View {
    @AppStorage("PKSNotesReadingTheme") private var themeID = NotesTheme.system.rawValue
    @AppStorage("PKSNotesFontAdjustment") private var fontAdjustment = 0.0
    @AppStorage("PKSNotesLineAdjustment") private var lineAdjustment = 0.0
    @AppStorage("PKSNotesWidthAdjustment") private var widthAdjustment = 0.0

    private var theme: NotesTheme { NotesTheme.restored(themeID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance & Typography", systemImage: "paintpalette")
                .font(.headline)
                .padding(.bottom, 1)

            ForEach(NotesTheme.allCases) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        themeID = option.rawValue
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: option.symbol)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Text(option.name)
                            .fontWeight(theme == option ? .semibold : .regular)
                        Spacer(minLength: 6)
                        if theme == option {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pks-theme-\(option.rawValue)")
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Text Size")
                    Spacer()
                    Text("\(theme.typography.bodySize + fontAdjustment, specifier: "%.1f") pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $fontAdjustment, in: -2...4)
                    .accessibilityIdentifier("pks-typography-size")
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Line Spacing")
                    Spacer()
                    Text("\(Int((theme.typography.lineSpacing + lineAdjustment) * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $lineAdjustment, in: -0.15...0.30)
                    .accessibilityIdentifier("pks-typography-leading")
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Reading Width")
                    Spacer()
                    Text("\(Int(theme.typography.pageWidth + widthAdjustment)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $widthAdjustment, in: -160...160)
                    .accessibilityIdentifier("pks-typography-width")
            }
            Button("Reset Typography") {
                fontAdjustment = 0
                lineAdjustment = 0
                widthAdjustment = 0
            }
            .disabled(fontAdjustment == 0 && lineAdjustment == 0 && widthAdjustment == 0)
            .font(.caption)
            .buttonStyle(.link)
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .padding(28)
        .frame(width: 450)
    }

}
