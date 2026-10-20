import Foundation

// Copy as One Line (iGhostVT/Backend/Session/OneLineText.swift) against
// selections as Ghostty reads them: the first row from where the selection
// began, every other row from column 0 with its gutter, painted padding
// kept, soft-wrapped rows already one line.

var failures: [String] = []

func check(_ text: String, columns: Int?, _ expected: String?, _ description: String) {
    let actual = OneLineText.join(text, columns: columns)
    if actual == expected {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description): \(actual.map { "\"\($0)\"" } ?? "nil") != \(expected.map { "\"\($0)\"" } ?? "nil")")
        failures.append(description)
    }
}

print("one-line: rows broken between words")
check(
    "Reply with only this, no   \n  tools: The quick fox   \n  river bank.",
    columns: 80,
    "Reply with only this, no tools: The quick fox river bank.",
    "a Claude Code prompt keeps the spaces its padding stood for",
)
check(
    "The quick brown fox jumps over the\n  lazy dog",
    columns: 40,
    "The quick brown fox jumps over the lazy dog",
    "a word that did not fit moved to the next row",
)
check(
    "aaaa bbbb cccc ddddd\nffff gggg hhhh iiii\njjjj",
    columns: 20,
    "aaaa bbbb cccc ddddd ffff gggg hhhh iiii jjjj",
    "a word ending exactly at the edge still gets its space",
)
check(
    "aaaa bbbb cccc ddddd\nffff gggg hhhh iiii\njjjj",
    columns: nil,
    "aaaa bbbb cccc ddddd ffff gggg hhhh iiii jjjj",
    "the same without the terminal's width",
)
check(
    "a short\n  line\n  another",
    columns: 80,
    "a short line another",
    "rows that end far from the edge are separate lines",
)
check("echo foo \nbar", columns: 80, "echo foo bar", "a space before the break is kept")
check("first\n\n\nsecond", columns: 80, "first second", "blank rows between paragraphs collapse to one space")
check("使用 Claude\n  Code 工具", columns: 12, "使用 Claude Code 工具", "a Latin word after CJK text keeps its space")

print("one-line: words split over rows")
check(
    "⏺ Bash(cat /Users/admin/Documents/GitHub/ow\n  ngoal-dev/iGhostVT/README.md)",
    columns: 42,
    "⏺ Bash(cat /Users/admin/Documents/GitHub/owngoal-dev/iGhostVT/README.md)",
    "a path split at the edge closes up",
)
check(
    "Documents/GitHub/ow\n  ngoal-dev/README.md)",
    columns: 42,
    "Documents/GitHub/owngoal-dev/README.md)",
    "a selection begun inside the path closes up",
)
check(
    "ow\n  ngoal-dev/README.md",
    columns: 42,
    "owngoal-dev/README.md",
    "a first row of one word is taken for the tail of a split word",
)
check(
    "  See https://example.com/a/very/long/path/th\n  at/keeps/going?x=1",
    columns: 45,
    "See https://example.com/a/very/long/path/that/keeps/going?x=1",
    "a link split at the edge closes up",
)
check(
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\naaaaaaa",
    columns: 40,
    String(repeating: "a", count: 87),
    "a word over three rows closes up",
)
check("这是一段很长的中文文本被折\n行了", columns: 26, "这是一段很长的中文文本被折行了", "CJK text broken mid-sentence closes up")
check("  这是一段很长的中文文本被\n  折行了", columns: 26, "这是一段很长的中文文本被折行了", "CJK text short of the edge still closes up")

print("one-line: shell continuations")
check(
    "docker run \\\n  --rm \\\n  image",
    columns: 80,
    "docker run --rm image",
    "a trailing backslash is taken out",
)
check("a path\\\nb", columns: 80, "a path\\ b", "a backslash inside a word is left alone")

print("one-line: not one line")
check("one row", columns: 80, nil, "a single row has nothing to join")
check("   \n   ", columns: 80, nil, "blank rows have no text")

print("one-line: widths")
let wide: [(Character, Bool)] = [("a", false), ("中", true), ("한", true), ("ア", true), ("😀", true), ("é", false), ("─", false)]
for (character, isWide) in wide {
    if OneLineText.isWide(character) == isWide {
        print("  ok   \(character) is \(isWide ? "wide" : "narrow")")
    } else {
        print("  FAIL \(character) is \(isWide ? "wide" : "narrow")")
        failures.append("width of \(character)")
    }
}

if failures.isEmpty {
    print("one-line: all passed")
} else {
    print("one-line: \(failures.count) failed")
    exit(1)
}
