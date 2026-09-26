import Foundation

public enum TokenKind: String, Sendable, CaseIterable {
    case keyword, type, function, string, number, comment, attribute, tag, property, variable
    case heading, emphasis, link, inserted, deleted, meta
}

public struct Token: Equatable, Sendable {
    public var range: NSRange
    public var kind: TokenKind

    public init(range: NSRange, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A regex-based highlighter. Each language is a list of rules tried in order at every position,
/// so comments and strings win over keywords inside them. Fast enough for a few megabytes.
public final class SyntaxHighlighter {
    struct Rule {
        let kind: TokenKind
        let pattern: String
        var inner: [Rule] = []
    }

    struct Grammar {
        let regex: NSRegularExpression
        let rules: [Rule]
        let inner: [Int: Grammar]
    }

    private static var cache: [Language: Grammar] = [:]
    private static let lock = NSLock()

    public static func tokens(in text: String, language: Language, limit: Int = 4_000_000) -> [Token] {
        let length = text.utf16.count
        guard length > 0, length <= limit, let grammar = grammar(for: language) else { return [] }
        var tokens: [Token] = []
        run(grammar, text: text, range: NSRange(location: 0, length: length), into: &tokens)
        return tokens
    }

    private static func run(_ grammar: Grammar, text: String, range: NSRange, into tokens: inout [Token]) {
        for match in grammar.regex.matches(in: text, options: [], range: range) {
            for index in 0..<grammar.rules.count {
                let groupRange = match.range(at: index + 1)
                guard groupRange.location != NSNotFound, groupRange.length > 0 else { continue }
                tokens.append(Token(range: groupRange, kind: grammar.rules[index].kind))
                if let inner = grammar.inner[index] {
                    run(inner, text: text, range: groupRange, into: &tokens)
                }
                break
            }
        }
    }

    static func grammar(for language: Language) -> Grammar? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[language] { return cached }
        guard let built = compile(rules(for: language)) else { return nil }
        cache[language] = built
        return built
    }

    private static func compile(_ rules: [Rule]) -> Grammar? {
        guard !rules.isEmpty else { return nil }
        let pattern = rules.map { "(\($0.pattern))" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            assertionFailure("Bad grammar: \(pattern)")
            return nil
        }
        var inner: [Int: Grammar] = [:]
        for (index, rule) in rules.enumerated() where !rule.inner.isEmpty {
            inner[index] = compile(rule.inner)
        }
        return Grammar(regex: regex, rules: rules, inner: inner)
    }

    // MARK: - Building blocks. Every group inside a pattern must be non-capturing.

    private static func words(_ list: String, caseInsensitive: Bool = false) -> String {
        let alternatives = list.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        let body = "\\b(?:" + alternatives.joined(separator: "|") + ")\\b"
        return caseInsensitive ? "(?i:\(body))" : body
    }

    private static let cLineComment = "//[^\\n]*"
    private static let cBlockComment = "/\\*[\\s\\S]*?(?:\\*/|\\z)"
    private static let hashComment = "#[^\\n]*"
    private static let doubleString = "\"(?:\\\\.|[^\"\\\\\\n])*\"?"
    private static let singleString = "'(?:\\\\.|[^'\\\\\\n])*'?"
    private static let backtickString = "`(?:\\\\.|[^`\\\\])*`?"
    private static let number = "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)\\b"
    private static let typeName = "\\b[A-Z][A-Za-z0-9_]*\\b"
    private static let functionCall = "\\b[a-z_][A-Za-z0-9_]*(?=\\s*\\()"

    private static func cFamily(keywords: String, extraStrings: [String] = [], attributes: String? = nil) -> [Rule] {
        var rules = [Rule(kind: .comment, pattern: cLineComment), Rule(kind: .comment, pattern: cBlockComment)]
        for s in extraStrings { rules.append(Rule(kind: .string, pattern: s)) }
        rules.append(Rule(kind: .string, pattern: doubleString))
        rules.append(Rule(kind: .string, pattern: singleString))
        if let attributes = attributes { rules.append(Rule(kind: .attribute, pattern: attributes)) }
        rules.append(Rule(kind: .keyword, pattern: words(keywords)))
        rules.append(Rule(kind: .type, pattern: typeName))
        rules.append(Rule(kind: .number, pattern: number))
        rules.append(Rule(kind: .function, pattern: functionCall))
        return rules
    }

    private static let cKeywords = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Bool bool true false NULL"

    static func rules(for language: Language) -> [Rule] {
        switch language {
        case .swift:
            return cFamily(
                keywords: "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as Any false is nil self Self super throws true try await async actor nonisolated isolated some any lazy weak unowned mutating nonmutating override final required convenience dynamic optional indirect get set willSet didSet macro consume borrowing consuming sending package",
                extraStrings: ["#?\"\"\"[\\s\\S]*?(?:\"\"\"#?|\\z)"],
                attributes: "@[A-Za-z_]\\w*|#(?:if|elseif|else|endif|available|unavailable|selector|keyPath|file|line|function|warning|error|Preview)\\b")
        case .javascript:
            return cFamily(
                keywords: "break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield async await of static get set null undefined true false NaN Infinity from as",
                extraStrings: [backtickString],
                attributes: "@[A-Za-z_]\\w*")
        case .typescript:
            return cFamily(
                keywords: "break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield async await of static get set null undefined true false NaN Infinity from as interface type enum implements namespace declare abstract readonly private public protected keyof infer is any unknown never string number boolean symbol bigint object satisfies module override",
                extraStrings: [backtickString],
                attributes: "@[A-Za-z_]\\w*")
        case .c:
            return cFamily(keywords: cKeywords, attributes: "^\\s*#\\s*[a-z]+")
        case .cpp:
            return cFamily(
                keywords: cKeywords + " alignas alignof and asm catch class constexpr const_cast decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not nullptr operator or private protected public reinterpret_cast static_assert static_cast template this thread_local throw try typeid typename using virtual override final concept requires co_await co_return co_yield consteval constinit",
                attributes: "^\\s*#\\s*[a-z]+")
        case .objc:
            return cFamily(
                keywords: cKeywords + " self super id nil Nil YES NO instancetype nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull in out inout bycopy byref oneway",
                extraStrings: ["@\"(?:\\\\.|[^\"\\\\\\n])*\"?"],
                attributes: "^\\s*#\\s*[a-z]+|@[A-Za-z_]\\w*")
        case .java:
            return cFamily(
                keywords: "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while var record sealed permits yield true false null def",
                extraStrings: ["\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)"],
                attributes: "@[A-Za-z_]\\w*")
        case .kotlin:
            return cFamily(
                keywords: "as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg",
                extraStrings: ["\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)"],
                attributes: "@[A-Za-z_]\\w*")
        case .csharp:
            return cFamily(
                keywords: "abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while var async await dynamic get set yield record init",
                extraStrings: ["@\"(?:\"\"|[^\"])*\"?"],
                attributes: "^\\s*#\\s*[a-z]+|\\[[A-Z]\\w*(?:\\([^)\\n]*\\))?\\]")
        case .go:
            return cFamily(
                keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota",
                extraStrings: [backtickString])
        case .rust:
            return cFamily(
                keywords: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while macro_rules",
                attributes: "#!?\\[[^\\]\\n]*\\]|\\b[a-z_]\\w*!")
        case .dart:
            return cFamily(
                keywords: "abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for Function get hide if implements import in interface is late library mixin new null on operator part required rethrow return set show static super switch sync this throw true try typedef var void while with yield",
                extraStrings: ["'''[\\s\\S]*?(?:'''|\\z)", "\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)"],
                attributes: "@[A-Za-z_]\\w*")
        case .scala:
            return cFamily(
                keywords: "abstract case catch class def do else extends false final finally for forSome if implicit import lazy match new null object override package private protected return sealed super this throw trait try true type val var while with yield given using then enum export",
                extraStrings: ["\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)"],
                attributes: "@[A-Za-z_]\\w*")
        case .php:
            var rules = cFamily(
                keywords: "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false null",
                attributes: "<\\?php|\\?>")
            rules.insert(Rule(kind: .comment, pattern: hashComment), at: 2)
            rules.insert(Rule(kind: .variable, pattern: "\\$[A-Za-z_]\\w*"), at: rules.count - 3)
            return rules
        case .python:
            return [
                Rule(kind: .comment, pattern: hashComment),
                Rule(kind: .string, pattern: "(?i:[rbuf]{0,2})\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)"),
                Rule(kind: .string, pattern: "(?i:[rbuf]{0,2})'''[\\s\\S]*?(?:'''|\\z)"),
                Rule(kind: .string, pattern: "(?i:[rbuf]{0,2})" + doubleString),
                Rule(kind: .string, pattern: "(?i:[rbuf]{0,2})" + singleString),
                Rule(kind: .attribute, pattern: "^\\s*@[\\w.]+"),
                Rule(kind: .keyword, pattern: words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield match case self cls")),
                Rule(kind: .type, pattern: typeName),
                Rule(kind: .number, pattern: number),
                Rule(kind: .function, pattern: functionCall),
            ]
        case .ruby:
            return [
                Rule(kind: .comment, pattern: "=begin[\\s\\S]*?(?:^=end|\\z)"),
                Rule(kind: .comment, pattern: hashComment),
                Rule(kind: .string, pattern: doubleString),
                Rule(kind: .string, pattern: singleString),
                Rule(kind: .attribute, pattern: ":[A-Za-z_]\\w*[?!]?"),
                Rule(kind: .variable, pattern: "@@?[A-Za-z_]\\w*|\\$[A-Za-z_]\\w*"),
                Rule(kind: .keyword, pattern: words("alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative include extend attr_accessor attr_reader attr_writer private public protected lambda proc puts raise")),
                Rule(kind: .type, pattern: typeName),
                Rule(kind: .number, pattern: number),
                Rule(kind: .function, pattern: functionCall),
            ]
        case .perl:
            return [
                Rule(kind: .comment, pattern: hashComment),
                Rule(kind: .string, pattern: doubleString),
                Rule(kind: .string, pattern: singleString),
                Rule(kind: .variable, pattern: "[$@%][A-Za-z_]\\w*"),
                Rule(kind: .keyword, pattern: words("my our local sub if elsif else unless while until for foreach do last next redo return use require package BEGIN END and or not eq ne lt gt le ge print")),
                Rule(kind: .number, pattern: number),
            ]
        case .r:
            return [
                Rule(kind: .comment, pattern: hashComment),
                Rule(kind: .string, pattern: doubleString),
                Rule(kind: .string, pattern: singleString),
                Rule(kind: .keyword, pattern: words("if else repeat while function for in next break TRUE FALSE NULL Inf NaN NA library return")),
                Rule(kind: .number, pattern: number),
                Rule(kind: .function, pattern: "\\b[A-Za-z_.][\\w.]*(?=\\s*\\()"),
            ]
        case .lua:
            return [
                Rule(kind: .comment, pattern: "--\\[=*\\[[\\s\\S]*?(?:\\]=*\\]|\\z)"),
                Rule(kind: .comment, pattern: "--[^\\n]*"),
                Rule(kind: .string, pattern: "\\[\\[[\\s\\S]*?(?:\\]\\]|\\z)"),
                Rule(kind: .string, pattern: doubleString),
                Rule(kind: .string, pattern: singleString),
                Rule(kind: .keyword, pattern: words("and break do else elseif end false for function goto if in local nil not or repeat return then true until while self")),
                Rule(kind: .number, pattern: number),
                Rule(kind: .function, pattern: functionCall),
            ]
        case .shell, .dockerfile, .makefile:
            var rules = [
                Rule(kind: .comment, pattern: "(?:^|(?<=\\s))#[^\\n]*"),
                Rule(kind: .string, pattern: "\"(?:\\\\.|[^\"\\\\])*\"?"),
                Rule(kind: .string, pattern: "'[^']*'?"),
                Rule(kind: .variable, pattern: "\\$\\{[^}\\n]*\\}?|\\$\\(\\(?|\\$[A-Za-z_]\\w*|\\$[@#?$!*0-9-]"),
            ]
            switch language {
            case .dockerfile:
                rules.append(Rule(kind: .keyword, pattern: "(?i:^\\s*(?:FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\\b)"))
            case .makefile:
                rules.append(Rule(kind: .function, pattern: "^[A-Za-z0-9_./%-]+(?=\\s*:(?!=))"))
                rules.append(Rule(kind: .property, pattern: "^[A-Za-z_][A-Za-z0-9_]*(?=\\s*[:+?]?=)"))
                rules.append(Rule(kind: .keyword, pattern: words("ifeq ifneq ifdef ifndef else endif include define endef export override")))
            default:
                break
            }
            rules.append(Rule(kind: .keyword, pattern: words("if then else elif fi for while until do done case esac function in return local export readonly declare select time break continue exit source alias unset shift trap eval exec set echo printf test cd")))
            rules.append(Rule(kind: .number, pattern: "\\b\\d+\\b"))
            return rules
        case .json:
            return [
                Rule(kind: .comment, pattern: cLineComment),
                Rule(kind: .comment, pattern: cBlockComment),
                Rule(kind: .property, pattern: "\"(?:\\\\.|[^\"\\\\\\n])*\"(?=\\s*:)"),
                Rule(kind: .string, pattern: doubleString),
                Rule(kind: .keyword, pattern: words("true false null")),
                Rule(kind: .number, pattern: "-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"),
            ]
        case .html, .xml:
            let attributes = [
                Rule(kind: .string, pattern: "\"[^\"]*\"?|'[^']*'?"),
                Rule(kind: .property, pattern: "[A-Za-z_:][\\w:.-]*(?=\\s*=)"),
            ]
            return [
                Rule(kind: .comment, pattern: "<!--[\\s\\S]*?(?:-->|\\z)"),
                Rule(kind: .string, pattern: "<!\\[CDATA\\[[\\s\\S]*?(?:\\]\\]>|\\z)"),
                Rule(kind: .meta, pattern: "<[!?][^>]*>?"),
                Rule(kind: .tag, pattern: "</?[A-Za-z][\\w:.-]*(?:[^<>\"']|\"[^\"]*\"|'[^']*')*/?>?", inner: attributes),
                Rule(kind: .attribute, pattern: "&(?:[A-Za-z]+|#\\d+|#x[0-9a-fA-F]+);"),
            ]
        case .css:
            return [
                Rule(kind: .comment, pattern: cBlockComment),
                Rule(kind: .comment, pattern: "(?:^|(?<=\\s))//[^\\n]*"),
                Rule(kind: .string, pattern: doubleString),
                Rule(kind: .string, pattern: singleString),
                Rule(kind: .keyword, pattern: "@[\\w-]+|!important\\b"),
                Rule(kind: .number, pattern: "#[0-9a-fA-F]{3,8}\\b"),
                Rule(kind: .property, pattern: "(?<![\\w-])[a-zA-Z-]+(?=\\s*:(?!:)[^;{}\\n]*(?:;|\\}|$))"),
                Rule(kind: .variable, pattern: "--[\\w-]+|\\$[\\w-]+"),
                Rule(kind: .type, pattern: "[.#][A-Za-z_-][\\w-]*"),
                Rule(kind: .number, pattern: "-?(?:\\d*\\.)?\\d+(?:px|em|rem|%|vh|vw|vmin|vmax|s|ms|deg|fr|pt|ch|ex)?\\b"),
                Rule(kind: .function, pattern: "\\b[a-z-]+(?=\\()"),
            ]
        case .sql:
            return [
                Rule(kind: .comment, pattern: "--[^\\n]*"),
                Rule(kind: .comment, pattern: cBlockComment),
                Rule(kind: .string, pattern: "'(?:''|[^'])*'?"),
                Rule(kind: .property, pattern: "\"(?:\"\"|[^\"])*\"|`[^`]*`"),
                Rule(kind: .keyword, pattern: words("select from where and or not insert into values update set delete create table view index drop alter add column primary key foreign references join inner left right outer full cross on group by order having limit offset as distinct union all exists in is null like between case when then else end asc desc default unique check constraint begin commit rollback transaction with recursive returning if replace trigger procedure function return declare", caseInsensitive: true)),
                Rule(kind: .type, pattern: words("int integer bigint smallint tinyint decimal numeric float double real char varchar text blob boolean bool date time timestamp datetime serial uuid json jsonb", caseInsensitive: true)),
                Rule(kind: .number, pattern: number),
                Rule(kind: .function, pattern: "\\b[A-Za-z_]\\w*(?=\\()"),
            ]
        case .yaml:
            return [
                Rule(kind: .comment, pattern: "(?:^|(?<=\\s))#[^\\n]*"),
                Rule(kind: .meta, pattern: "^(?:---|\\.\\.\\.)\\s*$"),
                Rule(kind: .property, pattern: "^[ \\t]*(?:- +)?[^\\s#:\\-\"'][^:#\\n]*?(?=:(?:[ \\t]|$))|^[ \\t]*(?:- +)?\"[^\"\\n]*\"(?=:)"),
                Rule(kind: .string, pattern: doubleString),
                Rule(kind: .string, pattern: "'(?:''|[^'\\n])*'?"),
                Rule(kind: .attribute, pattern: "[&*][\\w-]+|![\\w!/-]+"),
                Rule(kind: .keyword, pattern: words("true false yes no null on off True False Yes No Null TRUE FALSE NULL")),
                Rule(kind: .number, pattern: "(?<![\\w.])-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?(?![\\w.])"),
            ]
        case .toml, .ini:
            return [
                Rule(kind: .comment, pattern: "(?:^|(?<=\\s))[#;][^\\n]*"),
                Rule(kind: .tag, pattern: "^[ \\t]*\\[\\[?[^\\]\\n]*\\]\\]?"),
                Rule(kind: .property, pattern: "^[ \\t]*[\\w.\"'-]+(?=[ \\t]*[=:])"),
                Rule(kind: .string, pattern: "\"\"\"[\\s\\S]*?(?:\"\"\"|\\z)"),
                Rule(kind: .string, pattern: doubleString),
                Rule(kind: .string, pattern: singleString),
                Rule(kind: .keyword, pattern: words("true false yes no on off null")),
                Rule(kind: .number, pattern: "(?<![\\w.])-?\\d[\\d_:.-]*(?:[eE][+-]?\\d+)?(?![\\w])"),
            ]
        case .markdown:
            return [
                Rule(kind: .string, pattern: "^[ \\t]*(?:```|~~~)[\\s\\S]*?(?:^[ \\t]*(?:```|~~~)[ \\t]*$|\\z)"),
                Rule(kind: .heading, pattern: "^#{1,6}[ \\t][^\\n]*|^#{1,6}$"),
                Rule(kind: .comment, pattern: "^[ \\t]*>[^\\n]*"),
                Rule(kind: .meta, pattern: "^[ \\t]*(?:-[ \\t]*){3,}$|^[ \\t]*(?:\\*[ \\t]*){3,}$|^[ \\t]*(?:_[ \\t]*){3,}$"),
                Rule(kind: .keyword, pattern: "^[ \\t]*(?:[-*+]|\\d+[.)])(?=[ \\t])(?:[ \\t]+\\[[ xX]\\])?"),
                Rule(kind: .string, pattern: "`[^`\\n]+`"),
                Rule(kind: .link, pattern: "!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)|<https?://[^>\\s]+>"),
                Rule(kind: .emphasis, pattern: "\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__|(?<![*\\w])\\*[^*\\s][^*\\n]*\\*(?![*\\w])|(?<![_\\w])_[^_\\s][^_\\n]*_(?![_\\w])|~~[^~\\n]+~~"),
                Rule(kind: .tag, pattern: "</?[A-Za-z][^>\\n]*>"),
            ]
        case .diff:
            return [
                Rule(kind: .meta, pattern: "^(?:diff |index |--- |\\+\\+\\+ |new file|deleted file|similarity|rename )[^\\n]*"),
                Rule(kind: .heading, pattern: "^@@[^\\n]*"),
                Rule(kind: .inserted, pattern: "^\\+[^\\n]*"),
                Rule(kind: .deleted, pattern: "^-[^\\n]*"),
            ]
        }
    }
}
