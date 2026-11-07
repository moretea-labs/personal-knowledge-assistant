import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "PKSNotesAppearance"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    static func restored(_ value: String) -> AppAppearance {
        AppAppearance(rawValue: value) ?? .system
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let defaultsKey = "PKSNotesLanguage"

    var id: String { rawValue }

    static func restored(_ value: String) -> AppLanguage {
        AppLanguage(rawValue: value) ?? .system
    }

    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    var locale: Locale {
        Locale(identifier: resolved == .simplifiedChinese ? "zh-Hans" : "en")
    }

    static var current: AppLanguage {
        restored(UserDefaults.standard.string(forKey: defaultsKey) ?? AppLanguage.system.rawValue)
    }

    func text(_ english: String) -> String {
        guard resolved == .simplifiedChinese else { return english }
        return Self.zhHans[english] ?? english
    }

    private static let zhHans: [String: String] = [
        "System": "跟随系统",
        "Light": "浅色",
        "Dark": "深色",
        "Appearance": "外观",
        "Language": "语言",
        "Simplified Chinese": "简体中文",
        "English": "English",
        "Appearance & Language": "外观与语言",
        "Reading Theme": "阅读主题",
        "Typography": "排版",
        "Paper": "纸张",
        "Warm": "暖色",
        "Midnight": "午夜",
        "Graphite": "石墨",
        "Text Size": "文字大小",
        "Line Spacing": "行距",
        "Reading Width": "阅读宽度",
        "Reset Typography": "重置排版",

        "Cut": "剪切",
        "Copy": "复制",
        "Paste": "粘贴",
        "Bold": "粗体",
        "Italic": "斜体",
        "Inline Code": "行内代码",
        "Link": "链接",
        "Heading 1": "一级标题",
        "Heading 2": "二级标题",
        "Heading 3": "三级标题",
        "Bullet List": "项目列表",
        "Task": "任务",
        "New Markdown Note": "新建 Markdown 笔记",
        "Quick Open…": "快速打开…",
        "Toggle Edit / Preview": "切换编辑 / 预览",
        "Save Markdown": "保存 Markdown",
        "Find in PKS": "在 PKS 中查找",
        "Run PKS Search": "执行 PKS 搜索",
        "Refresh Files": "刷新文件",
        "Choose Folder…": "选择文件夹…",
        "Choose Folder": "选择文件夹",

        "Notes": "笔记",
        "Search": "搜索",
        "Edit": "编辑",
        "Split": "分栏",
        "Read": "阅读",
        "Return to Markdown": "返回 Markdown",
        "Mind Map": "思维导图",
        "Links and related notes": "链接与相关笔记",
        "Relationships": "关联",
        "Outgoing": "链接到",
        "Backlinks": "反向链接",
        "Related · PKS": "相关 · PKS",
        "No links from this note.": "此笔记没有链接到其他笔记。",
        "Finding notes that link here…": "正在查找链接到此处的笔记…",
        "No backlinks in this workspace.": "此工作区没有反向链接。",
        "Finding related knowledge…": "正在查找相关知识…",
        "No related PKS results.": "没有相关 PKS 结果。",
        "Saving Markdown automatically…": "正在自动保存 Markdown…",
        "Quick Open Note…": "快速打开笔记…",
        "New Mind Map": "新建思维导图",
        "Open Source in Browser": "在浏览器中打开来源",
        "Copy Source Link": "复制来源链接",
        "File actions and workspace options": "文件操作与工作区选项",

        "Rename": "重命名",
        "Name": "名称",
        "Cancel": "取消",
        "Change the name without moving the item. File extensions are preserved.": "仅修改名称，不移动项目；文件扩展名会保留。",
        "Move Folder to Trash?": "将文件夹移到废纸篓？",
        "Move to Trash": "移到废纸篓",
        "The folder and all of its contents will move to the macOS Trash, where they can be restored.": "文件夹及其中所有内容都会移到 macOS 废纸篓，可从废纸篓恢复。",
        "Search files…": "搜索文件…",
        "Cancel (Esc)": "取消（Esc）",
        "Type a name to find a note in your library.": "输入名称以查找资料库中的笔记。",
        "No files match your search.": "没有匹配的文件。",
        "New Note Here": "在此新建笔记",
        "PKS results · across all sources": "PKS 结果 · 全部来源",
        "Source actions": "来源操作",
        "Dismiss": "关闭",
        "PKS Notes": "PKS Notes",
        "PKS Library": "PKS 资料库",
        "iCloud Drive": "iCloud Drive",

        "Start with a central topic": "从中心主题开始",
        "The mind map is saved in the same Markdown note.": "思维导图保存在同一份 Markdown 笔记中。",
        "Create Mind Map": "创建思维导图",
        "Mind Map Import/Export": "思维导图导入/导出",
        "OK": "确定",
        "Add Child": "添加子节点",
        "Add child (Tab)": "添加子节点（Tab）",
        "Add Sibling": "添加同级节点",
        "Add sibling (Return)": "添加同级节点（Return）",
        "Rename node": "重命名节点",
        "Promote node": "提升节点层级",
        "Make child of previous sibling": "设为上一同级节点的子节点",
        "Delete Leaf": "删除叶子节点",
        "Delete Branch": "删除整条分支",
        "Delete selected branch?": "删除所选分支？",
        "The selected list branch and its child nodes will be removed from this note.": "所选列表分支及其子节点将从当前笔记中移除。",
        "Fit map to window": "适合窗口",
        "Zoom out": "缩小",
        "Zoom in": "放大",
        "Import MindNode v9 Package…": "导入 MindNode v9 文件…",
        "Export MindNode v9 Using Template…": "使用模板导出 MindNode v9…",
        "Import OPML from MindNode…": "从 MindNode 导入 OPML…",
        "Export OPML for MindNode…": "导出供 MindNode 使用的 OPML…",
        "Export PNG Image…": "导出 PNG 图片…",
        "Export PDF…": "导出 PDF…",
        "MindNode v9 package interchange, OPML, PNG and PDF export": "MindNode v9 文件交换、OPML、PNG 与 PDF 导出",
        "Quick find in PKS…": "在 PKS 中快速查找…",
        "NAVIGATION": "导航",
        "All Notes": "全部笔记",
        "PKS Search": "PKS 搜索",
        "Quick Open": "快速打开",
        "Quick Open a file in the current library": "快速打开当前资料库中的文件",
        "FOLDERS": "文件夹",
        "SEARCH RESULTS": "搜索结果",
        "Choose Notes Folder…": "选择笔记文件夹…",
        "Show in Finder": "在 Finder 中显示",
        "Current library folder": "当前资料库文件夹",
        "Loading local Markdown…": "正在加载本地 Markdown…",
        "Open with Default App": "使用默认应用打开",
        "Copy File Path": "复制文件路径",
        "Rename…": "重命名…",
        "Move to Folder…": "移动到文件夹…",
        "Copy to Folder…": "复制到文件夹…",
        "Copy Source Identifier": "复制来源标识",
        "Opening note…": "正在打开笔记…",
        "Double-click the margin to preview (⌘Return)": "双击页边距进入预览（⌘Return）",
        "Double-click to expand or collapse": "双击展开或折叠",
        "references": "处引用",
        "1 reference": "1 处引用",
        "Copy to Folder": "复制到文件夹",
        "Move to Folder": "移动到文件夹",
        "Choose a destination inside the current notes workspace.": "请选择当前笔记工作区内的目标文件夹。",
        "Could not save the pasted image inside this notes workspace.": "无法将粘贴的图片保存到当前笔记工作区。",
        "New Markdown note (⌘N)": "新建 Markdown 笔记（⌘N）",
        "Cannot preview this PDF": "无法预览此 PDF",
        "The original file may be unavailable or damaged.": "原始文件可能不可用或已损坏。",
        "Node title": "节点标题",
        "Open linked note": "打开链接笔记",
        "Import MindNode Package": "导入 MindNode 文件",
        "Select a .mindnode package. Only the node hierarchy is imported; original files are not modified.": "选择一个 .mindnode 文件。仅导入节点层级，不会修改原始文件。",
        "New MindNode v9 package exported. Check it in MindNode before relying on it; original template and Markdown were not changed.": "已导出新的 MindNode v9 文件。使用前请在 MindNode 中验证；原模板和 Markdown 未被修改。",
        "MindNode hierarchy imported into a new Markdown note. Themes, images, notes, tasks and cross-connections are not imported.": "MindNode 层级已导入到新的 Markdown 笔记；主题、图片、备注、任务和交叉连接不会导入。",
        "Import Mind Map from OPML": "从 OPML 导入思维导图",
        "Export for MindNode (OPML)": "导出供 MindNode 使用的 OPML",
        "This map is too large for a single PNG. Try PDF.": "此思维导图过大，无法导出为单张 PNG，请改用 PDF。",
        "Cannot render this mind map as an image.": "无法将此思维导图渲染为图片。",
        "Cannot render this mind map as a PDF.": "无法将此思维导图渲染为 PDF。",
        "Export Mind Map": "导出思维导图",
        "Select the existing iCloud folder once to grant macOS access.": "请选择一次现有的 iCloud 文件夹以授予 macOS 访问权限。",
        "Choose your existing Markdown folder once. No account is required.": "请选择现有 Markdown 文件夹；无需账号。",
        "Choose the existing Markdown directory (no import or duplication)": "选择现有 Markdown 目录（不会导入或复制）",
        "Folder opened, but macOS could not save permanent access. Choose it again next launch.": "文件夹已打开，但 macOS 无法保存永久访问权限；下次启动时请重新选择。",
        "Choose an existing Markdown folder.": "请选择现有 Markdown 文件夹。",
        "File is outside the selected workspace.": "文件不在所选工作区内。",
        "The original file is no longer available.": "原始文件已不可用。",
        "Only Markdown files inside the selected workspace can be edited.": "只能编辑所选工作区内的 Markdown 文件。",
        "The file changed outside PKS Notes. Reopen it before saving to avoid overwriting edits.": "文件已在 PKS Notes 外部被修改。请重新打开后再保存，以避免覆盖更改。",
        "Choose a notes folder before creating a note.": "创建笔记前请先选择笔记文件夹。",
        "Choose a folder inside the Markdown workspace.": "请选择 Markdown 工作区内的文件夹。",
        "Enter a simple note name without slashes.": "请输入不含斜杠的简单笔记名称。",
        "No available filename for a new note.": "没有可用于新笔记的文件名。",
        "Invalid note path.": "笔记路径无效。",
        "Cannot create note. The filename may already exist.": "无法创建笔记，文件名可能已存在。",
        "Searching PKS…": "正在搜索 PKS…",
        "PKS offline · no fallback index": "PKS 离线 · 无备用索引",
        "Link target not available or is ambiguous in this workspace.": "链接目标不可用，或在此工作区中存在歧义。",
        "Only existing files inside the notes folder can be moved to Trash.": "只有笔记文件夹内的现有文件才能移到废纸篓。",
        "Only existing files inside the notes folder can be renamed.": "只有笔记文件夹内的现有文件才能重命名。",
        "Enter a filename without slashes or special path characters.": "请输入不含斜杠或特殊路径字符的文件名。",
        "Enter a valid filename.": "请输入有效文件名。",
        "The new name is outside the notes folder.": "新名称超出了笔记文件夹范围。",
        "A file or folder with this name already exists.": "已存在同名文件或文件夹。",
        "Choose a destination inside the notes folder.": "请选择笔记文件夹内的目标位置。",
        "Choose an existing destination folder.": "请选择现有目标文件夹。",
        "The original item is no longer available.": "原始项目已不可用。",
        "A folder cannot be copied inside itself.": "文件夹不能复制到自身内部。",
        "A folder cannot be moved inside itself.": "文件夹不能移动到自身内部。",
        "The destination already contains an item with this name.": "目标位置已包含同名项目。",
        "The original file is not available locally.": "原始文件当前不在本地。",
        "Unable to copy source location.": "无法复制来源位置。",
        "Cannot open the note": "无法打开笔记",
        "Save failed": "保存失败",
        "Cannot create note": "无法创建笔记",
        "PKS search failed": "PKS 搜索失败",
        "Could not move to Trash": "无法移到废纸篓",
        "Could not rename file": "无法重命名文件",
        "Could not copy item": "无法复制项目",
        "Could not move item": "无法移动项目",
        "PKS preview failed": "PKS 预览失败",
        "No application could open": "没有应用可以打开",
        "Opening PDF…": "正在打开 PDF…",
        "Collapse folder": "折叠文件夹",
        "Expand folder": "展开文件夹",
        "Collapse": "折叠",
        "Expand": "展开",
        "matching sections": "个匹配段落",
        "Match": "匹配",
        "Search the existing PKS index.": "搜索现有 PKS 索引。",
        "Open a notes folder": "打开笔记文件夹",
        "Choose a note": "选择一篇笔记",
        "Open your existing Markdown folder. Files stay where they are.": "打开现有 Markdown 文件夹，文件保持原位。",
        "Select a document in the sidebar, or search your PKS knowledge with ⌘F.": "从侧栏选择文档，或使用 ⌘F 搜索 PKS 知识。",
        "matches": "个匹配",
        "documents": "个文档",
        "Preparing Markdown preview…": "正在准备 Markdown 预览…",
        "Attachment unavailable": "附件不可用",
        "Loading or missing attachment": "正在加载附件或附件缺失",
        "Link target not available in this workspace.": "链接目标在此工作区中不可用。",
        "Save": "保存",
        "Recent": "最近",
        "Favorites": "收藏",
        "RECENT NOTES": "最近笔记",
        "FAVORITES": "收藏",
        "No recent notes yet.": "还没有最近笔记。",
        "No favorite notes yet.": "还没有收藏笔记。",
        "Add to Favorites": "添加到收藏",
        "Remove from Favorites": "从收藏中移除",
        "Document Outline": "文档大纲",
        "No headings in this note.": "此笔记没有标题。",
        "Unsaved Markdown changes": "未保存的 Markdown 更改",
        "Discard Changes": "放弃更改",
        "Local file": "本地文件",
        "Web page": "网页",
        "PKS source": "PKS 来源"
    ]
}

private struct NotesLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .current
}

extension EnvironmentValues {
    var notesLanguage: AppLanguage {
        get { self[NotesLanguageEnvironmentKey.self] }
        set { self[NotesLanguageEnvironmentKey.self] = newValue }
    }
}
