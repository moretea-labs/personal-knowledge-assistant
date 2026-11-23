import Foundation

/// Derived entirely from Markdown task-list syntax. No task state is persisted
/// outside the canonical note.
enum MindMapTaskNode {
    struct Display: Equatable {
        let title: String
        let checked: Bool
    }

    static func parse(_ title: String) -> Display? {
        for (marker, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] {
            guard title.hasPrefix(marker) else { continue }
            let remainder = title.dropFirst(marker.count)
            guard !remainder.isEmpty else {
                return .init(title: "", checked: checked)
            }
            guard remainder.first == " " || remainder.first == "\t" else { continue }
            let visibleTitle = remainder.drop(while: { $0 == " " || $0 == "\t" })
            return .init(title: String(visibleTitle), checked: checked)
        }
        return nil
    }

    /// Edit the visible task label without exposing checkbox syntax in the field.
    static func titleForEditing(_ title: String) -> String {
        parse(title)?.title ?? title
    }

    /// Preserve the exact checkbox marker when replacing a task's visible label.
    static func replacingTitle(_ replacement: String, in originalTitle: String) -> String? {
        let title = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("\n"), !title.contains("\r") else { return nil }
        guard parse(originalTitle) != nil else { return title }
        return String(originalTitle.prefix(3)) + " " + title
    }

    static func toggle(in source: String, nodeID: Int) -> String? {
        guard let node = MindMapOutline.nodes(in: source).first(where: { $0.id == nodeID }),
              let task = parse(node.title) else { return nil }
        let prefix = task.checked ? "[ ]" : "[x]"
        let updatedTitle = task.title.isEmpty ? prefix : prefix + " " + task.title
        return MindMapOutline.rename(in: source, nodeID: nodeID, to: updatedTitle)
    }
}
