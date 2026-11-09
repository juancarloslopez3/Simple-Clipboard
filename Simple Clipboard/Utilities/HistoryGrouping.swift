import Foundation

/// An overflow folder of older history items, labelled by 1-based position range.
struct HistoryGroup: Identifiable {
    let id = UUID()
    let rangeLabel: String   // e.g. "6 – 10"
    let items: [ClipboardItem]
}

/// Splits a newest-first item list into inline items + overflow folders (CLAUDE.md §8e).
/// The same grouping feeds the menu and the hotkey panel.
enum HistoryGrouping {
    static func folders(for items: [ClipboardItem], inlineCount: Int, folderSize: Int) -> [HistoryGroup] {
        let size = max(1, folderSize)
        let inline = max(0, inlineCount)
        guard items.count > inline else { return [] }

        var groups: [HistoryGroup] = []
        var start = inline
        while start < items.count {
            let end = min(start + size, items.count)
            groups.append(HistoryGroup(rangeLabel: "\(start + 1) – \(end)", items: Array(items[start..<end])))
            start = end
        }
        return groups
    }
}
