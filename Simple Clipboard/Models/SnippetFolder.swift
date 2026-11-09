import Foundation
import SwiftData

/// A user-created folder of snippets, shown in the sidebar and the `Snippets ›`
/// submenu (CLAUDE.md §7 / §11).
@Model
final class SnippetFolder {
    var id: UUID = UUID()
    var name: String = "Snippets"
    var sortIndex: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Snippet.folder)
    var snippets: [Snippet] = []

    var createdAt: Date = Date.now

    init(name: String, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = .now
    }

    /// Snippets in stable manual order.
    var orderedSnippets: [Snippet] {
        snippets.sorted { $0.sortIndex < $1.sortIndex }
    }
}
