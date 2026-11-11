import SwiftUI

/// Native application Settings. Appearance, language and reading style use independent
/// persisted keys so one preference never becomes an authority for another.
struct NotesAppearanceSettings: View {
    @AppStorage(AppAppearance.defaultsKey) private var appearanceID = AppAppearance.system.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var languageID = AppLanguage.system.rawValue
    @AppStorage("PKSNotesReadingTheme") private var themeID = NotesTheme.system.rawValue
    @AppStorage("PKSNotesFontAdjustment") private var fontAdjustment = 0.0
    @AppStorage("PKSNotesLineAdjustment") private var lineAdjustment = 0.0
    @AppStorage("PKSNotesWidthAdjustment") private var widthAdjustment = 0.0
    @AppStorage("LeafspanAuxiliaryListPresentation") private var auxiliaryListPresentation = "pane"

    private var appearance: AppAppearance { AppAppearance.restored(appearanceID) }
    private var language: AppLanguage { AppLanguage.restored(languageID) }
    private var theme: NotesTheme { NotesTheme.restored(themeID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(language.text("Appearance & Language"), systemImage: "gearshape")
                .font(.headline)

            settingsGroup(title: language.text("Appearance")) {
                preferenceChoices(AppAppearance.allCases, selected: appearance) { option in
                    appearanceID = option.rawValue
                } label: { option in
                    language.text(option.rawValue.capitalized)
                } symbol: { option in
                    option.symbol
                }
            }

            settingsGroup(title: language.text("Language")) {
                preferenceChoices(AppLanguage.allCases, selected: language) { option in
                    languageID = option.rawValue
                } label: { option in
                    switch option {
                    case .system: language.text("System")
                    case .simplifiedChinese: language.text("Simplified Chinese")
                    case .english: language.text("English")
                    }
                } symbol: { option in
                    switch option {
                    case .system: "globe"
                    case .simplifiedChinese: "character.book.closed"
                    case .english: "textformat"
                    }
                }
            }

            Divider()

            settingsGroup(title: language.text("Lists and Document Outline")) {
                Picker(language.text("List presentation"), selection: $auxiliaryListPresentation) {
                    Text(language.text("Side Pane")).tag("pane")
                    Text(language.text("Large Sheet")).tag("sheet")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("pks-list-presentation-setting")
            }

            Divider()

            settingsGroup(title: language.text("Reading Theme")) {
                preferenceChoices(NotesTheme.allCases, selected: theme) { option in
                    withAnimation(.easeOut(duration: 0.15)) {
                        themeID = option.rawValue
                    }
                } label: { option in
                    language.text(option.name)
                } symbol: { option in
                    option.symbol
                }
            }

            Divider()

            Label(language.text("Typography"), systemImage: "textformat.size")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(language.text("Text Size"))
                    Spacer()
                    Text(String(format: "%.1f pt", theme.typography.bodySize + fontAdjustment))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $fontAdjustment, in: -2...4)
                    .accessibilityIdentifier("pks-typography-size")
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(language.text("Line Spacing"))
                    Spacer()
                    Text(String(format: "%d%%", Int((theme.typography.lineSpacing + lineAdjustment) * 100)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $lineAdjustment, in: -0.15...0.30)
                    .accessibilityIdentifier("pks-typography-leading")
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(language.text("Reading Width"))
                    Spacer()
                    Text(String(format: "%d pt", Int(theme.typography.pageWidth + widthAdjustment)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $widthAdjustment, in: -160...160)
                    .accessibilityIdentifier("pks-typography-width")
            }
            Button(language.text("Reset Typography")) {
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
        .frame(width: 470)
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }

    @ViewBuilder
    private func preferenceChoices<Option: Identifiable & Equatable>(
        _ options: [Option],
        selected: Option,
        action: @escaping (Option) -> Void,
        label: @escaping (Option) -> String,
        symbol: @escaping (Option) -> String
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(options) { option in
                Button {
                    action(option)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: symbol(option))
                            .font(.system(size: 12, weight: .medium))
                        Text(label(option))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(selected == option ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
