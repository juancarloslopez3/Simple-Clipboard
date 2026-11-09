import Foundation
import SwiftData
import SwiftUI
import AppKit

/// A user-created folder of snippets, shown in the sidebar and the `Snippets ›`
/// submenu.
@Model
final class SnippetFolder {
    var id: UUID = UUID()
    var name: String = "Snippets"
    var sortIndex: Int = 0
    /// Optional emoji shown instead of the folder glyph; empty = the default folder icon.
    var emoji: String = ""

    @Relationship(deleteRule: .cascade, inverse: \Snippet.folder)
    var snippets: [Snippet] = []

    var createdAt: Date = Date.now

    init(name: String, sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = .now
    }

    /// The characters of `text` that can be a folder icon, each once, in order: every emoji, plus
    /// the symbols beyond Latin-1 that aren't emoji (★ ⌘ → ♪ € ✓ •), so an icon can also be one the
    /// emoji lists lack. Letters, digits and plain punctuation don't count, so typing a word yields
    /// nothing. Digits, `#`, `*`, `©` and `®` count only in their emoji form (with U+FE0F, or the
    /// keycap U+20E3).
    static func iconCharacters(in text: String) -> [String] {
        var seen = Set<String>()
        return text.filter { character in
            let scalars = character.unicodeScalars
            guard let first = scalars.first else { return false }
            let isEmoji = scalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0xFF) }
                || (first.properties.isEmoji && scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 })
            let isSymbol = first.value > 0xFF && [.mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
                                                   .otherPunctuation].contains(first.properties.generalCategory)
            return isEmoji || isSymbol
        }
        .map(String.init)
        .filter { seen.insert($0).inserted }
    }

    /// Snippets in stable manual order.
    var orderedSnippets: [Snippet] {
        snippets.sorted { $0.sortIndex < $1.sortIndex }
    }
}

extension SnippetFolder {
    /// Name with the emoji in front, for menus and pickers that can't show an icon.
    var displayName: String { emoji.isEmpty ? name : "\(emoji) \(name)" }
}

/// A folder's icon: its emoji (drawn to a bitmap so sidebar lists, which only honor images,
/// still show it) or the plain folder glyph.
struct FolderGlyph: View {
    let emoji: String
    var body: some View {
        if emoji.isEmpty {
            Image(systemName: "folder")
        } else {
            Image(nsImage: Self.render(emoji))
                .renderingMode(.original)
        }
    }

    static func render(_ emoji: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 15)
        let str = NSAttributedString(string: emoji, attributes: [.font: font])
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let b = str.size()
            str.draw(at: NSPoint(x: (rect.width - b.width) / 2, y: (rect.height - b.height) / 2))
            return true
        }
        img.isTemplate = false
        return img
    }
}

// MARK: - Emoji picker

/// The emoji picker's sections: the user's own (`custom`, shown once it has any), then the system
/// picker's categories in the order of its category bar.
enum EmojiGroup: CaseIterable, Identifiable {
    case custom, people, nature, food, activities, travel, objects, symbols, flags
    var id: Self { self }

    /// Apple's own titles (the system picker's English and Spanish wording).
    var title: String {
        switch self {
        case .custom: String(localized: "Custom")
        case .people: String(localized: "Smileys & People"); case .nature: String(localized: "Animals & Nature")
        case .food: String(localized: "Food & Drink"); case .activities: String(localized: "Activity")
        case .travel: String(localized: "Travel & Places"); case .objects: String(localized: "Objects")
        case .symbols: String(localized: "Symbols"); case .flags: String(localized: "Flags")
        }
    }

    /// The glyph the system emoji picker draws for this category, then the closest public symbol in
    /// case a later macOS drops it. Most are private `emoji.*` SF Symbols — monochrome outlines, not
    /// color emoji — that only AppKit's private-symbol lookup reaches.
    private var symbolNames: (system: String, fallback: String) {
        switch self {
        case .custom: ("star", "star")
        case .people: ("emoji.face.grinning", "face.smiling")
        case .nature: ("emoji.dog.face", "dog")
        case .food: ("emoji.apple", "carrot")
        case .activities: ("emoji.soccer.ball", "soccerball")
        case .travel: ("emoji.automobile", "car.side")
        case .objects: ("lightbulb", "lightbulb")
        case .symbols: ("emoji.heart", "heart")
        case .flags: ("flag", "flag")
        }
    }

    @MainActor private static var iconCache: [EmojiGroup: NSImage] = [:]

    /// The category bar's glyph, as a template so it takes the foreground style.
    @MainActor var icon: Image {
        if let cached = Self.iconCache[self] { return Image(nsImage: cached).renderingMode(.template) }
        let names = symbolNames
        let symbol = Self.privateSymbol(names.system)
            ?? NSImage(systemSymbolName: names.fallback, accessibilityDescription: nil)
        guard let image = symbol?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) else {
            return Image(systemName: names.fallback)
        }
        image.isTemplate = true
        Self.iconCache[self] = image
        return Image(nsImage: image).renderingMode(.template)
    }

    /// `+[NSImage imageWithPrivateSystemSymbolName:accessibilityDescription:]`, the lookup the
    /// system picker itself uses: public symbols plus the OS's private symbol catalog.
    @MainActor private static func privateSymbol(_ name: String) -> NSImage? {
        let selector = NSSelectorFromString("imageWithPrivateSystemSymbolName:accessibilityDescription:")
        let imageClass: AnyObject = NSImage.self
        guard imageClass.responds(to: selector) else { return nil }
        return imageClass.perform(selector, with: name, with: nil)?.takeUnretainedValue() as? NSImage
    }
}

/// The picker's emoji: Apple's own lists in Apple's order (`SystemEmoji`), or the Unicode tables
/// (`UnicodeEmoji`) when those aren't available, with names and search.
@MainActor
enum EmojiCatalog {
    /// Each category's emoji in display order.
    static let grouped: [EmojiGroup: [String]] = SystemEmoji.categories() ?? UnicodeEmoji.categories
    private static let all = EmojiGroup.allCases.flatMap { grouped[$0] ?? [] }
    private static var names: [String: String] = [:]
    private static var searchWords: [String: [Substring]] = [:]

    /// The emoji's name in the app's language, sentence-cased ("Dog face", "Cara de perro").
    static func name(of emoji: String) -> String {
        if let name = names[emoji] { return name }
        let raw = SystemEmoji.name(of: emoji) ?? UnicodeEmoji.name(of: emoji)
        let name = raw.prefix(1).uppercased() + raw.dropFirst()
        names[emoji] = name
        return name
    }

    /// Search like the system picker: the user's `custom` emoji whose name matches first (Apple's
    /// index doesn't know the ones it lacks: "star" finds an added ★), then Apple's keyword index for
    /// the app's language, ranked as Apple ranks it ("happy", "carpeta"…), then every emoji with a
    /// name word starting with each typed word, for prefixes the index doesn't complete. Case and
    /// accents are ignored.
    static func search(_ query: String, custom: [String] = []) -> [String] {
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        func matches(_ emoji: String) -> Bool {
            let nameWords = Self.nameWords(of: emoji)
            return words.allSatisfy { word in nameWords.contains { $0.hasPrefix(word) } }
        }
        var seen = Set<String>()
        return (custom.filter(matches) + (SystemEmoji.search(query.trimmingCharacters(in: .whitespaces)) ?? []))
            .filter { seen.insert($0).inserted }
            + all.filter { !seen.contains($0) && matches($0) }
    }

    private static func nameWords(of emoji: String) -> [Substring] {
        if let words = searchWords[emoji] { return words }
        let words = fold(name(of: emoji)).split { !$0.isLetter && !$0.isNumber }
        searchWords[emoji] = words
        return words
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// The methods `SystemEmoji` calls with non-object arguments. `perform(_:)` only passes objects, so
/// these go through an `@objc` declaration of the same selectors, after `responds(to:)` checks.
@objc private protocol EMFLocaleDataMethods {
    @objc(emojiTokensForText:phoneticReading:options:searchType:includePrefixMatches:)
    func emojiTokens(forText text: String, phoneticReading: String?, options: UInt64, searchType: Int32,
                     includePrefixMatches: Bool) -> [NSObject]?
}

@objc private protocol EMFTokenMethods {
    @objc(nameForType:) func name(forType type: Int32) -> String?
    @objc(supportsSkinToneVariants) var supportsSkinToneVariants: Bool { get }
}

/// Apple's emoji data, from the private EmojiFoundation framework behind the system emoji picker:
/// its category lists and order (flags sorted by country name in the current language), names and
/// keyword search in the app's language, and skin-tone variants — plus that picker's skin-tone
/// choices, read from its preferences. Every call checks its class and selectors first
/// and returns nil or empty when they're missing, so a later macOS that moves them degrades to
/// `UnicodeEmoji` instead of crashing.
@MainActor
enum SystemEmoji {
    private static let isLoaded =
        dlopen("/System/Library/PrivateFrameworks/EmojiFoundation.framework/EmojiFoundation", RTLD_LAZY) != nil

    /// `EMFEmojiLocaleData` for the app's language: names and keywords in the language the UI shows.
    private static let localeData: NSObject? = {
        guard let localeDataClass = classObject("EMFEmojiLocaleData") else { return nil }
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return call(localeDataClass, "emojiLocaleDataWithLocaleIdentifier:", language) as? NSObject
    }()

    private static func classObject(_ name: String) -> AnyObject? {
        guard isLoaded, let cls = NSClassFromString(name) else { return nil }
        return cls as AnyObject
    }

    /// An object-returning method, if the receiver has it.
    private static func call(_ receiver: AnyObject, _ name: String, _ arguments: Any?...) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard receiver.responds(to: selector) else { return nil }
        let result = switch arguments.count {
        case 0: receiver.perform(selector)
        case 1: receiver.perform(selector, with: arguments[0])
        default: receiver.perform(selector, with: arguments[0], with: arguments[1])
        }
        return result?.takeUnretainedValue()
    }

    static func categories() -> [EmojiGroup: [String]]? {
        guard let category = classObject("EMFEmojiCategory") else { return nil }
        func list(_ selector: String) -> [String]? {
            guard let list = call(category, selector) as? [String], !list.isEmpty else { return nil }
            return list
        }
        let selectors: [(EmojiGroup, String)] = [
            (.people, "PeopleEmoji"), (.nature, "NatureEmoji"), (.food, "FoodAndDrinkEmoji"),
            (.activities, "ActivityEmoji"), (.travel, "TravelAndPlacesEmoji"), (.objects, "ObjectsEmoji"),
            (.symbols, "SymbolsEmoji"),
        ]
        var lists: [EmojiGroup: [String]] = [:]
        for (group, selector) in selectors {
            guard let emoji = list(selector) else { return nil }
            lists[group] = emoji
        }
        // The full flag list (the few non-country flags, then countries by name); `FlagsEmoji` alone is
        // only the non-country ones.
        lists[.flags] = list("computeEmojiFlagsSortedByLanguage")
            ?? (list("FlagsEmoji") ?? []) + UnicodeEmoji.countryFlags
        return lists
    }

    private static func token(_ emoji: String) -> NSObject? {
        guard let localeData, let tokenClass = classObject("EMFEmojiToken") else { return nil }
        return call(tokenClass, "emojiTokenWithString:localeData:", emoji, localeData) as? NSObject
    }

    private static func string(of token: NSObject) -> String? {
        call(token, "string") as? String
    }

    /// Apple's name for the emoji ("dog face", "flag of Spain").
    static func name(of emoji: String) -> String? {
        guard let token = token(emoji), token.responds(to: NSSelectorFromString("nameForType:")) else { return nil }
        let name = unsafeBitCast(token, to: (any EMFTokenMethods).self).name(forType: 2)   // 2 = display name
        return name?.isEmpty == false ? name : nil
    }

    /// Apple's keyword search, ranked; nil when unavailable.
    static func search(_ query: String) -> [String]? {
        let selector = NSSelectorFromString("emojiTokensForText:phoneticReading:options:searchType:includePrefixMatches:")
        guard let localeData, localeData.responds(to: selector) else { return nil }
        let tokens = unsafeBitCast(localeData, to: (any EMFLocaleDataMethods).self)
            .emojiTokens(forText: query, phoneticReading: nil, options: 0, searchType: 0, includePrefixMatches: true)
        return tokens?.compactMap(string(of:))
    }

    /// The emoji's skin-tone family as the system picker offers it — the five tones (plus the
    /// default for single-person emoji), or the 25 pairings for two-person ones — or empty.
    static func skinToneVariants(of emoji: String) -> [String] {
        guard let token = token(emoji), token.responds(to: NSSelectorFromString("supportsSkinToneVariants")),
              unsafeBitCast(token, to: (any EMFTokenMethods).self).supportsSkinToneVariants,
              let variants = call(token, "skinToneVariants") as? [NSObject] else { return [] }
        return variants.compactMap(string(of:))
    }

    /// The system picker's preferences (read only; nothing is written back).
    private static var preferences: [String: Any] {
        UserDefaults(suiteName: "com.apple.EmojiPreferences")?.dictionary(forKey: "EMFDefaultsKey") ?? [:]
    }

    /// The skin tone last chosen in the system picker, keyed by the default-tone emoji.
    static var skinTones: [String: String] { preferences["EMFSkinToneBaseKeyPreferences"] as? [String: String] ?? [:] }
}

/// The fallback catalog when `SystemEmoji` is unavailable: every single-scalar emoji, grouped by
/// code point (Unicode's own groups aren't exposed by the OS), plus country flags, with Unicode names.
@MainActor
enum UnicodeEmoji {
    static let categories: [EmojiGroup: [String]] = {
        var out: [EmojiGroup: [String]] = [:]
        for v in UInt32(0x00A9)...UInt32(0x1FAFF) {
            guard let u = Unicode.Scalar(v), u.properties.isEmoji,
                  u.properties.isEmojiPresentation || v > 0xFF, u.properties.name != nil else { continue }
            // Skip regional indicators and skin-tone modifiers.
            if (0x1F1E6...0x1F1FF).contains(v) || (0x1F3FB...0x1F3FF).contains(v) { continue }
            let ch = u.properties.isEmojiPresentation ? String(u) : String(u) + "\u{FE0F}"
            out[group(of: v), default: []].append(ch)
        }
        out[.flags, default: []].append(contentsOf: countryFlags)
        return out
    }()

    static let countryFlags: [String] = Locale.Region.isoRegions.compactMap { region in
        let code = region.identifier
        guard code.count == 2, code.allSatisfy(\.isLetter) else { return nil }
        let scalars = code.uppercased().unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
        return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : nil
    }

    static func name(of emoji: String) -> String {
        let scalars = Array(emoji.unicodeScalars)
        if scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) {
            let code = String(String.UnicodeScalarView(scalars.compactMap { Unicode.Scalar($0.value - 0x1F1E6 + 65) }))
            return (Locale.current.localizedString(forRegionCode: code) ?? code) + " flag"
        }
        return scalars.first?.properties.name?.lowercased() ?? emoji
    }

    private static func group(of v: UInt32) -> EmojiGroup {
        func inr(_ rs: ClosedRange<UInt32>...) -> Bool { rs.contains { $0.contains(v) } }
        if inr(0x1F3F3...0x1F3F4, 0x1F6A9...0x1F6A9, 0x1F38C...0x1F38C, 0x1F3C1...0x1F3C1) { return .flags }
        if inr(0x1F600...0x1F64F, 0x1F440...0x1F487, 0x1F90C...0x1F93A, 0x1F970...0x1F97F, 0x1F9B4...0x1F9BF,
               0x1F9D0...0x1F9DF, 0x1F9CD...0x1F9CF, 0x261D...0x261D, 0x270A...0x270D, 0x1F6B6...0x1F6B6,
               0x1F6C0...0x1F6C0, 0x1F6CC...0x1F6CC, 0x1F483...0x1F484, 0x1F5E3...0x1F5E3) { return .people }
        if inr(0x1F32D...0x1F32F, 0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x2615...0x2615, 0x1F95A...0x1F95A) { return .food }
        if inr(0x1F400...0x1F43F, 0x1F980...0x1F9AF, 0x1F300...0x1F320, 0x1F324...0x1F32C, 0x1F330...0x1F344,
               0x1F490...0x1F490, 0x1F4AE...0x1F4AE, 0x2600...0x2604, 0x2614...0x2614, 0x2744...0x2744, 0x26C4...0x26C5,
               0x26A1...0x26A1, 0x1F525...0x1F525, 0x1F4A7...0x1F4A7, 0x1F30A...0x1F30B, 0x1F3F5...0x1F3F5, 0x1F54A...0x1F54A) { return .nature }
        if inr(0x1F380...0x1F393, 0x1F3A0...0x1F3CA, 0x1F3CF...0x1F3D3, 0x1F3F8...0x1F3F9, 0x26BD...0x26BE, 0x26F3...0x26F3,
               0x26F8...0x26F8, 0x1F93B...0x1F94F, 0x1F3AE...0x1F3B9, 0x1F0CF...0x1F0CF, 0x1F004...0x1F004, 0x1F9E9...0x1F9E9) { return .activities }
        if inr(0x1F680...0x1F6C5, 0x1F6CB...0x1F6FF, 0x1F3D4...0x1F3F0, 0x1F3E0...0x1F3F0, 0x1F5FA...0x1F5FF, 0x1F30D...0x1F30F,
               0x26F0...0x26FA, 0x2708...0x2708, 0x26F5...0x26F5, 0x2693...0x2693, 0x1F301...0x1F301, 0x1F309...0x1F30C, 0x1F3A1...0x1F3A2,
               0x26E9...0x26EA, 0x26FD...0x26FD, 0x1F6D0...0x1F6D2) { return .travel }
        if inr(0x1F4A0...0x1F4A0, 0x1F4AF...0x1F4AF, 0x1F4A2...0x1F4AC, 0x1F493...0x1F49F, 0x1F500...0x1F53D, 0x1F7E0...0x1F7EB,
               0x2764...0x2764, 0x2190...0x21FF, 0x2B00...0x2BFF, 0x25A0...0x25FF, 0x2122...0x2139, 0x24C2...0x24C2, 0x203C...0x2049,
               0x3030...0x303D, 0x3297...0x3299, 0xA9...0xAE, 0x1F170...0x1F251, 0x267B...0x267F, 0x2660...0x2668, 0x26A0...0x26AB,
               0x2795...0x2797, 0x27B0...0x27BF, 0x2705...0x2705, 0x274C...0x274E, 0x2753...0x2757, 0x2733...0x2734, 0x2747...0x2747,
               0x2640...0x2642, 0x2648...0x2653, 0x2638...0x263A, 0x2620...0x2626, 0x262A...0x262F, 0x2716...0x2716) { return .symbols }
        return .objects
    }
}

/// The skin tone shown for each emoji that has them: the one last picked here, else the system
/// picker's choice (as the system picker shows them).
@MainActor
enum EmojiSkinTones {
    private static var variantCache: [String: [String]] = [:]

    static func preferences() -> [String: String] {
        SystemEmoji.skinTones.merging(own) { _, mine in mine }
    }

    static func remember(_ variant: String, for base: String) {
        var tones = own
        tones[base] = variant
        UserDefaults.standard.set(tones, forKey: Pref.Key.folderEmojiSkinTones)
    }

    static func variants(of emoji: String) -> [String] {
        if let variants = variantCache[emoji] { return variants }
        let variants = SystemEmoji.skinToneVariants(of: emoji)
        variantCache[emoji] = variants
        return variants
    }

    private static var own: [String: String] {
        UserDefaults.standard.dictionary(forKey: Pref.Key.folderEmojiSkinTones) as? [String: String] ?? [:]
    }
}

/// The emoji and symbols the user added to the picker's Custom section, newest first.
@MainActor
enum CustomEmoji {
    static var saved: [String] {
        UserDefaults.standard.stringArray(forKey: Pref.Key.folderCustomEmoji) ?? []
    }

    static func save(_ emoji: [String]) {
        UserDefaults.standard.set(emoji, forKey: Pref.Key.folderCustomEmoji)
    }
}

/// Popover content for choosing a folder's emoji, laid out like the system emoji picker: a search
/// field, Apple's categories in Apple's order, and the category bar along the bottom with the
/// system picker's own glyphs (it scrolls to a category). The arrow keys move through the grid
/// and Return picks; click and hold an emoji to choose its skin tone. "Add Emoji…" keeps any emoji
/// or symbol — ones the lists lack too — in a Custom section on top (right-click one to remove it).
struct FolderEmojiPicker: View {
    let current: String
    /// Whether the Add popover offers the system's Emoji & Symbols viewer. Off in the history panel,
    /// whose light dismiss closes it on the first click in the viewer (another process's window).
    var offersCharacterViewer = true
    let onPick: (String) -> Void
    @State private var query = ""
    @State private var results: [String] = []
    @State private var skinTones = EmojiSkinTones.preferences()
    @State private var customEmoji = CustomEmoji.saved
    @State private var addingCustom = false
    /// The category under the top edge of the grid, for the bar's highlight; nil until scrolled, which
    /// highlights the first one.
    @State private var activeGroup: EmojiGroup?
    /// Where each category's header sits in the scrolled content. Measured once laid out; scrolling
    /// doesn't change it.
    @State private var sectionTops: [EmojiGroup: CGFloat] = [:]
    /// Drives the bar's jumps.
    @State private var scrollPosition = ScrollPosition(idType: EmojiGroup.self)
    @State private var jump = JumpState()
    /// The keyboard selection.
    @State private var selection: GridPosition?
    @FocusState private var focused: Bool

    private static let columnCount = 9
    private static let cellSize: CGFloat = 36
    private static let cellSpacing: CGFloat = 2
    private static let sectionSpacing: CGFloat = 6
    nonisolated private static let contentSpace = "FolderEmojiPicker.content"

    fileprivate struct GridPosition: Hashable {
        var section: Int
        var index: Int
    }

    /// A run of emoji under one header; `id` nil is the search results (no header).
    private struct Section: Identifiable {
        let id: EmojiGroup?
        let emoji: [String]
    }

    /// Whether a jump from the bar is animating. A plain reference, so setting it doesn't redraw:
    /// any state change mid-jump — the highlight following the categories it passed — stopped the
    /// animation right there, short of its category.
    private final class JumpState {
        var animating = false
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The last category whose header is at or above the grid's top edge. (Not the scroll position's
    /// id: that's the first category whose top is in view, the next one while a long category fills
    /// the whole grid.)
    private func groupAtTop(_ geometry: ScrollGeometry) -> EmojiGroup? {
        groups.last { sectionTops[$0, default: .infinity] <= geometry.contentOffset.y + 1 }
    }

    /// The categories shown: Custom only once it has something.
    private var groups: [EmojiGroup] {
        EmojiGroup.allCases.filter { $0 != .custom || !customEmoji.isEmpty }
    }

    private var sections: [Section] {
        if searching { return [Section(id: nil, emoji: results)] }
        return groups.map { Section(id: $0, emoji: $0 == .custom ? customEmoji : EmojiCatalog.grouped[$0] ?? []) }
    }

    var body: some View {
        let sections = self.sections
        VStack(spacing: 8) {
            // A plain field on the popover's glass (as in the history panel), not an opaque box.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search emoji", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
                        handleKey(press.key, in: sections)
                    }
                    .onSubmit { if let emoji = selectedEmoji(in: sections) ?? results.first { onPick(emoji) } }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: .capsule)
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain stack of categories (each grid is still lazy inside), so every category
                    // sits at its real position. A `LazyVStack` only estimates where the ones it hasn't
                    // loaded are — they run 500 to 2,000 pt — so a jump from the bar landed in the
                    // wrong category, scrolled through blank space, or drew two categories over each other.
                    VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                        if searching {
                            grid(results, section: 0)
                            if results.isEmpty {
                                Text("No emoji found").foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.top, 40)
                            }
                        } else {
                            // Identified by the category itself, which `scrollPosition` must match exactly.
                            ForEach(Array(groups.enumerated()), id: \.element) { offset, group in
                                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                                    .onGeometryChange(for: CGFloat.self) {
                                        $0.frame(in: .named(Self.contentSpace)).minY
                                    } action: { sectionTops[group] = $0 }
                                grid(sections[offset].emoji, section: offset, removable: group == .custom)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .coordinateSpace(.named(Self.contentSpace))
                }
                .frame(height: 320)
                .scrollPosition($scrollPosition, anchor: .top)
                .onScrollGeometryChange(for: EmojiGroup?.self, of: groupAtTop) { _, group in
                    if !jump.animating, let group, group != activeGroup { activeGroup = group }
                }
                .onScrollPhaseChange { _, phase, context in
                    jump.animating = phase == .animating
                    if phase == .idle, let group = groupAtTop(context.geometry), group != activeGroup {
                        activeGroup = group
                    }
                }
                .onChange(of: selection) { _, position in
                    if let position { proxy.scrollTo(position) }
                }
            }
            if !searching {
                Divider()
                HStack(spacing: 0) {
                    ForEach(groups) { group in
                        let active = group == (activeGroup ?? groups.first)
                        Button {
                            scroll(to: group)
                        } label: {
                            group.icon
                                .foregroundStyle(active ? Color.primary : Color.secondary)
                                .frame(width: 30, height: 30)
                                .background {
                                    if active { Circle().fill(.primary.opacity(0.12)) }
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(group.title)
                    }
                }
            }
            HStack {
                Button("Add Emoji…", systemImage: "plus") { addingCustom = true }
                    .buttonStyle(.glass)
                    .popover(isPresented: $addingCustom, arrowEdge: .bottom) {
                        CustomEmojiAdder(offersCharacterViewer: offersCharacterViewer, onAdd: addCustom)
                    }
                Button("Use Default Icon") { onPick("") }
                    .buttonStyle(.glass)
                    .disabled(current.isEmpty)
            }
        }
        .padding(10)
        .frame(width: 360)
        .onAppear { focused = true }
        .onChange(of: query) {
            // Emoji or symbols typed or pasted into the field are the results themselves.
            let typed = SnippetFolder.iconCharacters(in: query)
            results = typed.isEmpty ? EmojiCatalog.search(query, custom: customEmoji) : typed
            selection = searching && !results.isEmpty ? GridPosition(section: 0, index: 0) : nil
        }
    }

    private func scroll(to group: EmojiGroup) {
        selection = nil
        activeGroup = group
        jump.animating = true
        withAnimation { scrollPosition.scrollTo(id: group, anchor: .top) }
    }

    /// Puts what the Add popover found at the front of Custom (moving any already there) and shows it.
    private func addCustom(_ emoji: [String]) {
        addingCustom = false
        customEmoji = emoji + customEmoji.filter { !emoji.contains($0) }
        CustomEmoji.save(customEmoji)
        query = ""
        scroll(to: .custom)
    }

    private func removeCustom(_ emoji: String) {
        customEmoji.removeAll { $0 == emoji }
        CustomEmoji.save(customEmoji)
        selection = nil
        if customEmoji.isEmpty, activeGroup == .custom { activeGroup = nil }
    }

    private func grid(_ emoji: [String], section sectionIndex: Int, removable: Bool = false) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellSize), spacing: Self.cellSpacing),
                                 count: Self.columnCount),
                  spacing: Self.cellSpacing) {
            ForEach(Array(emoji.enumerated()), id: \.offset) { index, base in
                let position = GridPosition(section: sectionIndex, index: index)
                let shown = skinTones[base] ?? base
                EmojiCell(base: base, shown: shown, isCurrent: !current.isEmpty && shown == current,
                          isSelected: selection == position, onPick: onPick,
                          onRemove: removable ? { removeCustom(base) } : nil) { variant in
                    EmojiSkinTones.remember(variant, for: base)
                    skinTones[base] = variant
                    onPick(variant)
                }
                .id(position)
            }
        }
    }

    private func selectedEmoji(in sections: [Section]) -> String? {
        guard let selection, sections.indices.contains(selection.section),
              sections[selection.section].emoji.indices.contains(selection.index) else { return nil }
        let base = sections[selection.section].emoji[selection.index]
        return skinTones[base] ?? base
    }

    /// Arrow keys move the selection through the grid (Left/Right in reading order, Up/Down by
    /// rows, both crossing into the neighboring sections); Return picks it. With nothing selected
    /// the first arrow selects the top of the category in view; Return falls through to `onSubmit`.
    private func handleKey(_ key: KeyEquivalent, in sections: [Section]) -> KeyPress.Result {
        if key == .return {
            guard let emoji = selectedEmoji(in: sections) else { return .ignored }
            onPick(emoji)
            return .handled
        }
        let counts = sections.map(\.emoji.count)
        guard let first = counts.firstIndex(where: { $0 > 0 }) else { return .ignored }
        guard let from = selection, counts.indices.contains(from.section), counts[from.section] > from.index else {
            let start = sections.firstIndex { $0.id != nil && $0.id == activeGroup && !$0.emoji.isEmpty } ?? first
            selection = GridPosition(section: start, index: 0)
            return .handled
        }
        guard let to = Self.move(from, key, counts: counts, columns: Self.columnCount) else { return .ignored }
        selection = to
        return .handled
    }

    /// Where an arrow key takes the selection in sections of `counts` emoji laid out `columns` wide;
    /// it stays put at either end, and nil means the key isn't an arrow.
    fileprivate static func move(_ from: GridPosition, _ key: KeyEquivalent, counts: [Int], columns: Int) -> GridPosition? {
        let filled = counts.indices.filter { counts[$0] > 0 }
        let count = counts[from.section]
        let column = from.index % columns
        let next = filled.first { $0 > from.section }
        let previous = filled.last { $0 < from.section }
        var to = from
        switch key {
        case .rightArrow:
            if from.index + 1 < count { to.index += 1 } else if let next { to = GridPosition(section: next, index: 0) }
        case .leftArrow:
            if from.index > 0 { to.index -= 1 } else if let previous {
                to = GridPosition(section: previous, index: counts[previous] - 1)
            }
        case .downArrow:
            if from.index + columns < count {
                to.index += columns
            } else if from.index / columns < (count - 1) / columns {
                to.index = count - 1                                   // into a shorter last row
            } else if let next {
                to = GridPosition(section: next, index: min(column, counts[next] - 1))
            }
        case .upArrow:
            if from.index >= columns {
                to.index -= columns
            } else if let previous {
                to = GridPosition(section: previous,
                                  index: min((counts[previous] - 1) / columns * columns + column, counts[previous] - 1))
            }
        default:
            return nil
        }
        return to
    }
}

/// One emoji in the picker's grid. Click picks it; click and hold opens its skin tones (as in the
/// system picker) when it has them; with `onRemove` (the Custom section), right-click removes it.
private struct EmojiCell: View {
    let base: String
    let shown: String
    let isCurrent: Bool
    let isSelected: Bool
    let onPick: (String) -> Void
    let onRemove: (() -> Void)?
    let onPickTone: (String) -> Void
    @State private var choosingTone = false
    /// Set when click-and-hold opened the tones, so that click's release doesn't also pick.
    @State private var held = false

    var body: some View {
        Button {
            if held { held = false } else { onPick(shown) }
        } label: {
            Text(shown)
        }
        .buttonStyle(EmojiTileStyle(isSelected: isSelected, isCurrent: isCurrent))
        .help(EmojiCatalog.name(of: shown))
        .accessibilityLabel(EmojiCatalog.name(of: shown))
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
            guard !EmojiSkinTones.variants(of: base).isEmpty else { return }
            held = true
            choosingTone = true
        })
        .popover(isPresented: $choosingTone, arrowEdge: .bottom) { tones }
        .onChange(of: choosingTone) { _, open in if !open { held = false } }
        .contextMenu {
            if let onRemove { Button("Remove from Custom", action: onRemove) }
        }
    }

    /// The tones in a row, or the 5 × 5 pairings of a two-person emoji under its default.
    private var tones: some View {
        let variants = EmojiSkinTones.variants(of: base)
        return VStack(spacing: 6) {
            if !variants.contains(base) {
                toneButton(base)
                Divider()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 2), count: variants.count > 6 ? 5 : variants.count),
                      spacing: 2) {
                ForEach(variants, id: \.self, content: toneButton)
            }
        }
        .padding(8)
    }

    private func toneButton(_ variant: String) -> some View {
        Button {
            choosingTone = false
            onPickTone(variant)
        } label: {
            Text(variant)
        }
        .buttonStyle(EmojiTileStyle(isCurrent: variant == shown))
        .help(EmojiCatalog.name(of: variant))
    }
}

/// The picker's "Add Emoji…" popover: type or paste any emoji or symbol, even one the lists lack, or
/// pick it in the system's Emoji & Symbols viewer, to keep it in the Custom section. What will be
/// added shows below the field as it's typed.
private struct CustomEmojiAdder: View {
    let offersCharacterViewer: Bool
    let onAdd: ([String]) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let found = SnippetFolder.iconCharacters(in: text)
        VStack(alignment: .leading, spacing: 8) {
            // Styled like the picker's search field.
            TextField("Emoji or symbols", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { if !found.isEmpty { onAdd(found) } }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: .capsule)
            Group {
                if !found.isEmpty {
                    Text(found.joined(separator: " ")).font(.system(size: 22)).lineLimit(2)
                } else if text.isEmpty {
                    Text("Any emoji or symbol, even ones not in the list.")
                } else {
                    Text("Only emoji and symbols can be added.")
                }
            }
            .font(.callout)
            .foregroundStyle(found.isEmpty ? HierarchicalShapeStyle.secondary : .primary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            HStack {
                if offersCharacterViewer {
                    // What's picked there goes into the focused field.
                    Button("Emoji & Symbols", systemImage: "globe") {
                        focused = true
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                    .buttonStyle(.glass)
                }
                Spacer()
                Button("Add") { onAdd(found) }
                    .buttonStyle(.glassProminent)
                    .disabled(found.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { focused = true }
    }
}

/// An emoji tile: a light rounded highlight on hover, an accent one for the keyboard selection,
/// and a ring around the folder's current icon.
private struct EmojiTileStyle: ButtonStyle {
    var isSelected = false
    var isCurrent = false

    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, isSelected: isSelected, isCurrent: isCurrent)
    }

    private struct Tile: View {
        let configuration: Configuration
        let isSelected: Bool
        let isCurrent: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 24))
                .frame(width: 36, height: 36)
                .background(highlight, in: .rect(cornerRadius: 8))
                .overlay {
                    if isCurrent { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5) }
                }
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }

        private var highlight: Color {
            if isSelected { return Color.accentColor.opacity(0.3) }
            if configuration.isPressed { return Color.primary.opacity(0.18) }
            return Color.primary.opacity(hovering ? 0.1 : 0)
        }
    }
}
