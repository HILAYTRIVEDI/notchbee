import Foundation

/// A small, dependency-free tokenizer for the languages that show up in agent replies. It favours speed and
/// robustness over grammar completeness: unknown languages return one plain token.
public enum SyntaxHighlighter {
    public enum Kind: Sendable {
        case plain, keyword, string, number, comment, type, function, property, tag, attribute
        case punctuation, variable, addition, deletion, heading
    }

    public struct Token: Equatable, Sendable {
        public let text: String
        public let kind: Kind
    }

    struct Grammar {
        var keywords: Set<String>
        var lineComments: [String] = ["//"]
        var blockComment: (open: String, close: String)? = ("/*", "*/")
        var quotes: [Character] = ["\"", "'"]
        var multilineQuotes: [Character] = []
        var tripleQuotes = false
        var caseInsensitive = false
        var identifierExtras: Set<Character> = ["_", "$"]
        var dollarVariables = false
        var decorators = false
        var propertyAfterColon = false
        var typesByCapital = true
    }

    private static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

    private static let literals = "true false null nil undefined None True False NaN Infinity self this super"
    private static let jsKeywords = words(literals + " const let var function return if else for while do switch case break continue new delete typeof instanceof in of class extends import export from default async await try catch finally throw yield static get set interface type enum implements public private protected readonly abstract declare namespace module as satisfies void keyof")
    private static let swiftKeywords = words(literals + " func let var if else guard return for while repeat switch case default break continue class struct enum protocol extension import init deinit where in is as try throws throw async await actor public private fileprivate internal open static final override mutating nonisolated some any typealias associatedtype subscript defer do catch inout lazy weak unowned @MainActor @Observable")
    private static let pythonKeywords = words(literals + " def class return if elif else for while in not and or is import from as with try except finally raise pass break continue lambda yield global nonlocal assert del async await match case print")
    private static let rustKeywords = words(literals + " fn let mut if else for while loop match return struct enum impl trait pub use mod crate as in ref move where async await const static type dyn unsafe extern break continue Self Some Ok Err")
    private static let goKeywords = words(literals + " func var const if else for range switch case default return break continue go defer chan select struct interface map type package import fallthrough goto iota make len cap append")
    private static let javaKeywords = words(literals + " class interface enum extends implements import package public private protected static final abstract void int long double float boolean char byte short new return if else for while do switch case default break continue try catch finally throw throws synchronized volatile instanceof var val fun when object companion data sealed override suspend namespace using string readonly")
    private static let cKeywords = words(literals + " int long double float char short unsigned signed void struct union enum typedef static const extern inline sizeof if else for while do switch case default break continue return goto auto register volatile class public private protected namespace template typename using new delete virtual override constexpr nullptr include define ifdef ifndef endif #include #define")
    private static let shellKeywords = words("if then else elif fi for while until do done case esac in function select return exit export local readonly source alias unset set echo cd ls cat grep sed awk npm npx pnpm yarn git docker brew sudo curl rm mv cp mkdir touch chmod xcodebuild swift node python python3 pip make")
    private static let sqlKeywords = words("select from where and or not in is null like between join left right inner outer full cross on group by order having limit offset insert into values update set delete create table drop alter add column index primary key foreign references unique default as distinct union all case when then else end count sum avg min max with returning true false asc desc exists")
    private static let rubyKeywords = words(literals + " def class module end if elsif else unless while until for in do begin rescue ensure raise return yield require include extend attr_accessor attr_reader attr_writer puts nil then case when lambda proc")
    private static let yamlKeywords = words("true false null yes no on off")
    private static let phpKeywords = words(literals + " function class public private protected static return if else elseif foreach for while echo new use namespace extends implements interface trait try catch finally throw require include const abstract final array isset empty")

    private static func grammar(for language: String) -> Grammar? {
        switch language {
        case "javascript", "typescript", "jsx", "tsx", "json5":
            var grammar = Grammar(keywords: jsKeywords, quotes: ["\"", "'"], multilineQuotes: ["`"])
            grammar.decorators = true
            return grammar
        case "swift": 
            var grammar = Grammar(keywords: swiftKeywords, multilineQuotes: [])
            grammar.decorators = true
            return grammar
        case "python":
            var grammar = Grammar(keywords: pythonKeywords, lineComments: ["#"], blockComment: nil)
            grammar.tripleQuotes = true
            grammar.decorators = true
            return grammar
        case "rust": return Grammar(keywords: rustKeywords)
        case "go": return Grammar(keywords: goKeywords, multilineQuotes: ["`"])
        case "java", "kotlin", "csharp", "scala", "dart": return Grammar(keywords: javaKeywords)
        case "c", "cpp", "objc": return Grammar(keywords: cKeywords)
        case "php": return Grammar(keywords: phpKeywords, lineComments: ["//", "#"])
        case "ruby": return Grammar(keywords: rubyKeywords, lineComments: ["#"], blockComment: nil)
        case "bash":
            var grammar = Grammar(keywords: shellKeywords, lineComments: ["#"], blockComment: nil)
            grammar.dollarVariables = true
            grammar.identifierExtras = ["_", "-"]
            grammar.typesByCapital = false
            return grammar
        case "yaml", "toml":
            var grammar = Grammar(keywords: yamlKeywords, lineComments: ["#"], blockComment: nil)
            grammar.propertyAfterColon = true
            grammar.identifierExtras = ["_", "-", "."]
            grammar.typesByCapital = false
            return grammar
        case "sql":
            var grammar = Grammar(keywords: sqlKeywords, lineComments: ["--"], quotes: ["'", "\""], caseInsensitive: true)
            grammar.typesByCapital = false
            return grammar
        case "css", "scss":
            var grammar = Grammar(keywords: words("important @media @import @keyframes @font-face @supports"), lineComments: ["//"], quotes: ["\"", "'"])
            grammar.propertyAfterColon = true
            grammar.identifierExtras = ["_", "-"]
            grammar.typesByCapital = false
            return grammar
        case "json":
            var grammar = Grammar(keywords: words("true false null"), lineComments: ["//"])
            grammar.propertyAfterColon = true
            grammar.typesByCapital = false
            return grammar
        default: return nil
        }
    }

    private static let aliases: [String: String] = [
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "node": "javascript", "ts": "typescript",
        "mts": "typescript", "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "terminal": "bash",
        "py": "python", "python3": "python", "rb": "ruby", "rs": "rust", "golang": "go", "kt": "kotlin",
        "cs": "csharp", "c++": "cpp", "cc": "cpp", "h": "c", "hpp": "cpp", "m": "objc", "yml": "yaml",
        "htm": "html", "xml": "html", "svg": "html", "vue": "html", "patch": "diff", "jsonc": "json",
        "postgres": "sql", "postgresql": "sql", "mysql": "sql", "sqlite": "sql", "md": "markdown",
        "objective-c": "objc", "swiftui": "swift"
    ]

    public static func canonicalLanguage(_ raw: String?) -> String? {
        guard var name = raw?.lowercased(), !name.isEmpty else { return nil }
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        if name.hasPrefix("language-") { name.removeFirst(9) }
        return aliases[name] ?? name
    }

    public static func tokens(_ code: String, language: String?) -> [Token] {
        guard let language = canonicalLanguage(language), code.utf8.count <= 60_000 else {
            return [Token(text: code, kind: .plain)]
        }
        switch language {
        case "diff": return diffTokens(code)
        case "html": return markupTokens(code)
        default:
            guard let grammar = grammar(for: language) else { return [Token(text: code, kind: .plain)] }
            return scan(Array(code), grammar: grammar, json: language == "json")
        }
    }

    private static func diffTokens(_ code: String) -> [Token] {
        var tokens: [Token] = []
        let lines = code.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let kind: Kind
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { kind = .heading }
            else if line.hasPrefix("@@") { kind = .keyword }
            else if line.hasPrefix("+") { kind = .addition }
            else if line.hasPrefix("-") { kind = .deletion }
            else { kind = .plain }
            tokens.append(Token(text: index < lines.count - 1 ? line + "\n" : line, kind: kind))
        }
        return tokens
    }

    private static func markupTokens(_ code: String) -> [Token] {
        var builder = Builder()
        let chars = Array(code)
        var i = 0
        while i < chars.count {
            if chars[i] == "<" {
                if chars[i...].starts(with: Array("<!--")) {
                    let end = find(Array("-->"), in: chars, from: i + 4).map { $0 + 3 } ?? chars.count
                    builder.add(String(chars[i..<end]), .comment)
                    i = end
                    continue
                }
                var j = i + 1
                var inQuote: Character?
                while j < chars.count {
                    if let quote = inQuote { if chars[j] == quote { inQuote = nil } }
                    else if chars[j] == "\"" || chars[j] == "'" { inQuote = chars[j] }
                    else if chars[j] == ">" { break }
                    j += 1
                }
                let end = min(chars.count, j + 1)
                tokenizeTag(Array(chars[i..<end]), into: &builder)
                i = end
            } else {
                var j = i
                while j < chars.count, chars[j] != "<" { j += 1 }
                builder.add(String(chars[i..<j]), .plain)
                i = j
            }
        }
        return builder.finish()
    }

    private static func tokenizeTag(_ tag: [Character], into builder: inout Builder) {
        var i = 0
        var first = true
        while i < tag.count {
            let c = tag[i]
            if c == "<" || c == ">" || c == "/" || c == "?" || c == "!" || c == "=" {
                builder.add(String(c), .punctuation)
                i += 1
            } else if c == "\"" || c == "'" {
                var j = i + 1
                while j < tag.count, tag[j] != c { j += 1 }
                j = min(tag.count, j + 1)
                builder.add(String(tag[i..<j]), .string)
                i = j
            } else if c.isLetter || c == "_" {
                var j = i
                while j < tag.count, tag[j].isLetter || tag[j].isNumber || "-_:.".contains(tag[j]) { j += 1 }
                builder.add(String(tag[i..<j]), first ? .tag : .attribute)
                first = false
                i = j
            } else {
                builder.add(String(c), .plain)
                i += 1
            }
        }
    }

    private struct Builder {
        var tokens: [Token] = []
        mutating func add(_ text: String, _ kind: Kind) {
            guard !text.isEmpty else { return }
            if let last = tokens.last, last.kind == kind {
                tokens[tokens.count - 1] = Token(text: last.text + text, kind: kind)
            } else {
                tokens.append(Token(text: text, kind: kind))
            }
        }
        func finish() -> [Token] { tokens }
    }

    private static func find(_ needle: [Character], in chars: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, chars.count >= needle.count, from <= chars.count - needle.count else { return nil }
        for i in from...(chars.count - needle.count) where chars[i] == needle[0] && Array(chars[i..<(i + needle.count)]) == needle {
            return i
        }
        return nil
    }

    private static func hasPrefix(_ chars: [Character], at i: Int, _ prefix: String) -> Bool {
        let p = Array(prefix)
        guard i + p.count <= chars.count else { return false }
        for k in 0..<p.count where chars[i + k] != p[k] { return false }
        return true
    }

    private static func scan(_ chars: [Character], grammar: Grammar, json: Bool) -> [Token] {
        var builder = Builder()
        var i = 0
        let count = chars.count
        while i < count {
            let c = chars[i]

            if let line = grammar.lineComments.first(where: { hasPrefix(chars, at: i, $0) }) {
                _ = line
                var j = i
                while j < count, chars[j] != "\n" { j += 1 }
                builder.add(String(chars[i..<j]), .comment)
                i = j
                continue
            }
            if let block = grammar.blockComment, hasPrefix(chars, at: i, block.open) {
                let end = find(Array(block.close), in: chars, from: i + block.open.count).map { $0 + block.close.count } ?? count
                builder.add(String(chars[i..<end]), .comment)
                i = end
                continue
            }
            if grammar.tripleQuotes, hasPrefix(chars, at: i, "\"\"\"") || hasPrefix(chars, at: i, "'''") {
                let delimiter = String(repeating: String(c), count: 3)
                let end = find(Array(delimiter), in: chars, from: i + 3).map { $0 + 3 } ?? count
                builder.add(String(chars[i..<end]), .string)
                i = end
                continue
            }
            if grammar.quotes.contains(c) || grammar.multilineQuotes.contains(c) {
                let multiline = grammar.multilineQuotes.contains(c)
                var j = i + 1
                while j < count {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == c { j += 1; break }
                    if chars[j] == "\n", !multiline { break }
                    j += 1
                }
                j = min(j, count)
                var kind = Kind.string
                if grammar.propertyAfterColon, json {
                    var k = j
                    while k < count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                    if k < count, chars[k] == ":" { kind = .property }
                }
                builder.add(String(chars[i..<j]), kind)
                i = j
                continue
            }
            if c == "$", grammar.dollarVariables {
                var j = i + 1
                if j < count, chars[j] == "{" || chars[j] == "(" {
                    j += 1
                    while j < count, chars[j] != "}" && chars[j] != ")" && chars[j] != "\n" { j += 1 }
                    j = min(count, j + 1)
                } else {
                    while j < count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || "@*#?!".contains(chars[j]) && j == i + 1 { j += 1 }
                }
                builder.add(String(chars[i..<j]), .variable)
                i = j
                continue
            }
            if c == "@", grammar.decorators, i + 1 < count, chars[i + 1].isLetter {
                var j = i + 1
                while j < count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." { j += 1 }
                builder.add(String(chars[i..<j]), .attribute)
                i = j
                continue
            }
            if c.isNumber || (c == "." && i + 1 < count && chars[i + 1].isNumber && (i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber))) {
                var j = i + 1
                while j < count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." && j + 1 < count && chars[j + 1].isNumber { j += 1 }
                builder.add(String(chars[i..<j]), .number)
                i = j
                continue
            }
            if c == "#", grammar.propertyAfterColon, !json, i + 1 < count, chars[i + 1].isHexDigit {
                var j = i + 1
                while j < count, chars[j].isHexDigit { j += 1 }
                builder.add(String(chars[i..<j]), .number)
                i = j
                continue
            }
            if c.isLetter || c == "_" || (c == "$" && !grammar.dollarVariables) {
                var j = i + 1
                while j < count, chars[j].isLetter || chars[j].isNumber || grammar.identifierExtras.contains(chars[j]) { j += 1 }
                // Trailing hyphens belong to operators, not identifiers.
                while j > i + 1, chars[j - 1] == "-" || chars[j - 1] == "." { j -= 1 }
                let word = String(chars[i..<j])
                let lookup = grammar.caseInsensitive ? word.lowercased() : word
                var k = j
                while k < count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                let next: Character? = k < count ? chars[k] : nil
                let kind: Kind
                if grammar.keywords.contains(lookup) { kind = .keyword }
                else if grammar.propertyAfterColon, next == ":" { kind = .property }
                else if next == "(" { kind = .function }
                else if grammar.typesByCapital, let first = word.first, first.isUppercase, word.count > 1 { kind = .type }
                else { kind = .plain }
                builder.add(word, kind)
                i = j
                continue
            }
            if "{}()[];,.:<>=+-*/%&|!?^~".contains(c) {
                builder.add(String(c), .punctuation)
            } else {
                builder.add(String(c), .plain)
            }
            i += 1
        }
        return builder.finish()
    }
}
