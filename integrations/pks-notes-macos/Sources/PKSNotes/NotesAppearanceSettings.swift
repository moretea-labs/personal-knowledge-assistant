import SwiftUI
import MarkdownUI

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
    @State private var installedThemes: [CommunityReadingTheme] = []
    @State private var previewTheme: NotesTheme?
    @State private var themeMessage: String?
    @State private var removalTarget: CommunityReadingTheme?
    @State private var confirmingRemoval = false

    private var appearance: AppAppearance { AppAppearance.restored(appearanceID) }
    private var language: AppLanguage { AppLanguage.restored(languageID) }
    private var theme: NotesTheme { NotesTheme.restored(themeID) }

    var body: some View {
        ScrollView {
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

            settingsGroup(title: language.text("Community Themes")) {
                Button(language.text("Import Theme…")) { importCommunityTheme() }
                    .accessibilityIdentifier("pks-community-theme-import")
                ForEach(installedThemes) { package in
                    let candidate = NotesTheme.community(package)
                    HStack(spacing: 8) {
                        Image(systemName: themeID == candidate.rawValue ? "checkmark.circle.fill" : "paintpalette")
                            .foregroundStyle(themeID == candidate.rawValue ? Color.accentColor : Color.secondary)
                        Text(package.name)
                            .lineLimit(1)
                        Spacer()
                        Button(language.text("Preview")) { previewTheme = candidate }
                            .accessibilityIdentifier("pks-community-theme-preview-" + package.id)
                        Button(language.text("Apply")) { themeID = candidate.rawValue }
                            .disabled(themeID == candidate.rawValue)
                        Menu {
                            Button(language.text("Export Theme…")) { exportCommunityTheme(package) }
                            Button(language.text("Remove Theme"), role: .destructive) {
                                removalTarget = package
                                confirmingRemoval = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .accessibilityLabel(language.text("Theme Actions"))
                    }
                    .padding(.vertical, 4)
                }
                if case .community = theme {
                    Button(language.text("Revert to System Theme")) {
                        themeID = NotesTheme.system.rawValue
                    }
                    .buttonStyle(.link)
                }
                if let themeMessage {
                    Text(themeMessage)
                        .foregroundStyle(.secondary)
                        .font(.caption)
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
        }
        .frame(width: 470, height: 640)
        .onAppear { installedThemes = CommunityThemeStore.application.installed() }
        .sheet(item: $previewTheme) { communityPreview($0) }
        .confirmationDialog(language.text("Remove Theme?"),
                            isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(language.text("Remove Theme"), role: .destructive) { removeCommunityTheme() }
            Button(language.text("Cancel"), role: .cancel) { removalTarget = nil }
        }
    }


    @MainActor
    private func importCommunityTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = language.text("Choose a .leafspan-theme file.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let imported = try CommunityThemeStore.application.importFile(url)
            installedThemes = CommunityThemeStore.application.installed()
            themeMessage = nil
            previewTheme = .community(imported)
        } catch {
            themeMessage = language.text(error.localizedDescription)
        }
    }

    @MainActor
    private func exportCommunityTheme(_ package: CommunityReadingTheme) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = package.id + ".leafspan-theme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try CommunityThemeStore.application.export(package, to: url)
            themeMessage = nil
        } catch {
            themeMessage = language.text(error.localizedDescription)
        }
    }

    @MainActor
    private func removeCommunityTheme() {
        guard let package = removalTarget else { return }
        do {
            try CommunityThemeStore.application.delete(id: package.id)
            if themeID == NotesTheme.community(package).rawValue {
                themeID = NotesTheme.system.rawValue
            }
            installedThemes = CommunityThemeStore.application.installed()
            themeMessage = nil
        } catch {
            themeMessage = language.text(error.localizedDescription)
        }
        removalTarget = nil
    }

    private func communityPreview(_ candidate: NotesTheme) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(candidate.name).font(.headline)
                Spacer()
                Button(language.text("Close")) { previewTheme = nil }
                    .buttonStyle(.plain)
            }
            ScrollView {
                Markdown(language.resolved == .simplifiedChinese ? """
                # 第一章：课程笔记

                ## 重点与例证

                阅读时可以标记**关键概念**，并保留[参考资料](https://example.org)。

                > 将重要原文和自己的理解放在一起。

                - 整理本章的核心观点
                - 记录需要复习的内容

                """ : """
                # Chapter Notes

                ## Ideas and evidence

                Mark **key concepts** and keep a [reference](https://example.org).

                > Keep an important excerpt with your own interpretation.

                - Summarize the main ideas
                - Review the open questions

                """)
                    .markdownTheme(.pksReading(candidate, fontAdjustment: 0, lineAdjustment: 0))
                    .font(.system(size: candidate.typography.bodySize, design: candidate.typography.design))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .background(candidate.canvas)
            .frame(height: 350)
            HStack {
                Spacer()
                Button(language.text("Apply Theme")) {
                    themeID = candidate.rawValue
                    previewTheme = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 590)
        .accessibilityIdentifier("pks-community-theme-preview")
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
