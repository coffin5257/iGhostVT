import Foundation

/// Copy as One Line: a selection over several rows put back on one, for a
/// command or a sentence a program broke over rows.
///
/// The selection reads as Ghostty gives it: rows the terminal soft-wrapped
/// are already one line, every other row break is a newline, nothing is
/// trimmed, the first row starts where the selection began and every other
/// row at column 0. A program that lays out its own text (Claude Code, any
/// Ink program) breaks rows itself, in one of two ways:
///
/// - at a space, between words — the space is gone from the screen, so the
///   rows join with one;
/// - inside a word longer than the row (a path, a link, CJK text with no
///   spaces), filling the row to its right edge — the rows join with
///   nothing.
///
/// Every row's leading blanks are layout (a gutter, an indent) and go. What
/// tells the two breaks apart is where the row ends: one that stops short
/// of the edge, or ends in blanks it painted, did not split a word; one
/// that reaches it did only if the word on both sides of the break, put
/// together, is wider than a row could hold — a wrapper never splits a word
/// that fits. Two wide (CJK) characters meet with nothing between them
/// either way. A shell continuation (` \` at a row's end) is taken out.
enum OneLineText {
    /// How far short of the right edge a row may end and still count as
    /// reaching it: a program's text box can stop a few columns before the
    /// terminal's.
    static let edgeSlack = 4

    /// The selection on one line, or nil when it is one row or has no text.
    /// `columns` is the terminal's width; without it the widest row stands
    /// in for it.
    static func join(_ text: String, columns: Int?) -> String? {
        let rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard rows.count > 1 else { return nil }
        let width = columns ?? rows.map { displayWidth(of: $0) }.max() ?? 0
        var line = ""
        // The row before the next text, while that text has yet to come.
        var previous: (raw: Substring, index: Int)?
        for (index, raw) in rows.enumerated() {
            let content = raw.drop { $0 == " " || $0 == "\t" }
            guard !content.allSatisfy({ $0 == " " || $0 == "\t" }) else { continue }
            if let previous {
                line = trimmingTrailingBlanks(line)
                // A blank row between them: a paragraph ended, no word split.
                let gap = index > previous.index + 1
                    ? " "
                    : separator(after: previous.raw, isFirst: previous.index == 0, before: raw, width: width, line: &line)
                line += gap
            }
            line += content
            previous = (raw, index)
        }
        line = trimmingTrailingBlanks(line)
        return line.isEmpty ? nil : line
    }

    /// What goes between `line` (ending with row `raw`'s text) and the next
    /// row, `next`. A shell continuation is taken off `line` here.
    private static func separator(
        after raw: Substring,
        isFirst: Bool,
        before next: Substring,
        width: Int,
        line: inout String,
    ) -> String {
        let text = trimmingTrailingBlanks(raw)
        if text.hasSuffix("\\"), text.dropLast().last.map({ $0 == " " || $0 == "\t" }) ?? true {
            line = trimmingTrailingBlanks(line.dropLast())
            return line.isEmpty ? "" : " "
        }
        // Blanks painted after the text: the row stopped short of its edge.
        if text.count != raw.count { return " " }
        let nextContent = next.drop { $0 == " " || $0 == "\t" }
        guard let last = text.last, let first = nextContent.first else { return " " }
        if isWide(last), isWide(first) { return "" }
        let tail = text.reversed().prefix { $0 != " " && $0 != "\t" }
        let head = nextContent.prefix { $0 != " " && $0 != "\t" }
        // The first row begins wherever the selection did, so where it ends
        // on screen is unknown, and so is how much of its last word lies
        // before the selection: a row that is all one word is taken to be
        // the tail of a word too long for a row.
        if isFirst {
            if tail.count == text.count { return "" }
        } else {
            // A row the terminal soft-wrapped into this one spans several
            // rows on screen; it ends where its last one does.
            let end = displayWidth(of: raw) % max(width, 1)
            if end != 0, end < width - edgeSlack { return " " }
        }
        let indent = displayWidth(of: next.prefix { $0 == " " || $0 == "\t" })
        let word = displayWidth(of: tail) + displayWidth(of: head)
        return word > width - indent ? "" : " "
    }

    private static func trimmingTrailingBlanks(_ text: some StringProtocol) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let before = text.index(before: end)
            guard text[before] == " " || text[before] == "\t" else { break }
            end = before
        }
        return String(text[..<end])
    }

    /// Cells `text` takes on screen: two for a wide character, one for any
    /// other.
    static func displayWidth(of text: some Sequence<Character>) -> Int {
        text.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    /// Whether `character` takes two cells: East Asian wide and fullwidth
    /// characters, and emoji.
    static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if character.unicodeScalars.count > 1, scalar.properties.isEmojiPresentation || character.unicodeScalars.contains("\u{FE0F}") {
            return true
        }
        switch scalar.value {
        case 0x1100 ... 0x115F, 0x2E80 ... 0x303E, 0x3041 ... 0x33FF, 0x3400 ... 0x4DBF,
             0x4E00 ... 0x9FFF, 0xA000 ... 0xA4CF, 0xAC00 ... 0xD7A3, 0xF900 ... 0xFAFF,
             0xFE30 ... 0xFE4F, 0xFF00 ... 0xFF60, 0xFFE0 ... 0xFFE6,
             0x1F300 ... 0x1F64F, 0x1F900 ... 0x1F9FF, 0x20000 ... 0x3FFFD:
            return true
        default:
            return scalar.properties.isEmojiPresentation
        }
    }
}
