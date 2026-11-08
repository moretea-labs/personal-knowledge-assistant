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
            if title == marker { return .init(title: "", checked: checked) }
            if title.hasPrefix(marker + " ") {
                return .init(title: String(title.dropFirst(marker.count + 1)), checked: checked)
            }
        }
        return nil
    }

    static func toggle(in source: String, nodeID: Int) -> String? {
        guard let node = MindMapOutline.nodes(in: source).first(where: { $0.id == nodeID }),
              let task = parse(node.title) else { return nil }
        let prefix = task.checked ? "[ ]" : "[x]"
        let updatedTitle = task.title.isEmpty ? prefix : prefix + " " + task.title
        return MindMapOutline.rename(in: source, nodeID: nodeID, to: updatedTitle)
    }
}
