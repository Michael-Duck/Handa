import AppKit
import HandaCore

/// Renders Markdown into native attributed text: headings, lists, task lists, quotes,
/// highlighted code blocks, tables, links and local images. Uses Foundation's CommonMark parser.
enum MarkdownRenderer {
    struct Style {
        var bodySize: CGFloat = 15
        var codeSize: CGFloat = 13
        var imageMaxWidth: CGFloat = 640
    }

    static let codeBackground = Theme.dynamic(light: Theme.hex(0xF5F2EF), dark: Theme.hex(0x2A2730))

    /// Marks text that `MarkdownTextView` decorates: code block backgrounds, quote bars and heading rules.
    /// Drawing these by hand avoids NSTextBlock, whose layout is fragile (it hung on macOS 26).
    static let codeBlockKey = NSAttributedString.Key("HandaCodeBlock")
    static let quoteKey = NSAttributedString.Key("HandaQuote")
    static let ruleKey = NSAttributedString.Key("HandaRule")
    static let quoteBar = Theme.dynamic(light: Theme.hex(0xE7DDD6), dark: Theme.hex(0x4A4350))
    static let headerBackground = Theme.dynamic(light: Theme.hex(0xF7F4F1), dark: Theme.hex(0x2A2730))

    private typealias Component = PresentationIntent.IntentType

    private final class TableState {
        let table: NSTextTable
        let alignments: [NSTextAlignment]
        var row = -1
        var rowIdentity: Int?
        var nextColumn = 0
        var isHeader = false

        init(columns: [PresentationIntent.TableColumn]) {
            table = NSTextTable()
            table.numberOfColumns = max(1, columns.count)
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.setContentWidth(100, type: .percentageValueType)
            alignments = columns.map { column in
                switch column.alignment {
                case .center: return .center
                case .right: return .right
                default: return .natural
                }
            }
        }
    }

    static func render(_ markdown: String, baseURL: URL? = nil, style: Style = Style()) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options, baseURL: baseURL) else {
            return NSAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: style.bodySize), .foregroundColor: NSColor.labelColor])
        }
        var renderer = Renderer(style: style, baseURL: baseURL)
        for run in parsed.runs {
            renderer.append(text: String(parsed[run.range].characters),
                            components: run.presentationIntent?.components ?? [],
                            inline: run.inlinePresentationIntent ?? [],
                            link: run.link,
                            imageURL: run.imageURL)
        }
        renderer.finish()
        return renderer.output
    }

    private struct Renderer {
        let style: Style
        let baseURL: URL?
        let output = NSMutableAttributedString()
        var lastBlock: [Int]?
        var lastParagraph = NSParagraphStyle()
        var lastAttributes: [NSAttributedString.Key: Any] = [:]
        var seenItems = Set<Int>()
        var tables: [Int: TableState] = [:]
        var activeTable: TableState?
        var endsWithNewline = true

        init(style: Style, baseURL: URL?) {
            self.style = style
            self.baseURL = baseURL
        }

        var bodyFont: NSFont { NSFont.systemFont(ofSize: style.bodySize) }

        mutating func endParagraph() {
            guard output.length > 0, !endsWithNewline else { return }
            var attributes = lastAttributes
            attributes[.paragraphStyle] = lastParagraph
            write("\n", attributes)
        }

        /// Appends text and remembers whether the output now ends a paragraph.
        mutating func write(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            guard !text.isEmpty else { return }
            output.append(NSAttributedString(string: text, attributes: attributes))
            endsWithNewline = text.hasSuffix("\n")
        }

        mutating func finish() {
            if let table = activeTable { padRow(table) }
            activeTable = nil
        }

        mutating func append(text rawText: String, components: [Component], inline: InlinePresentationIntent,
                             link: URL?, imageURL: URL?) {
            // Outermost first: parents are created before their children, so they have smaller identities.
            let ordered = components.sorted { $0.identity < $1.identity }
            let blockID = ordered.map(\.identity)
            var text = rawText
            if inline.contains(.softBreak) { text = " " }
            if inline.contains(.lineBreak) { text = "\u{2028}" }

            let tableComponent = ordered.first { if case .table = $0.kind { return true }; return false }
            if tableComponent == nil, let table = activeTable {
                endParagraph()
                padRow(table)
                activeTable = nil
            }

            let paragraph = NSMutableParagraphStyle()
            var prefix: String?
            var font = bodyFont
            var color = NSColor.labelColor
            var isCode = false
            var codeLanguage: Language?
            var codeBlock: Int?
            var quote: Int?
            var quoteDepth = 0
            var rule = false

            if blockID != lastBlock {
                endParagraph()
            }

            paragraph.lineHeightMultiple = 1.22
            paragraph.paragraphSpacing = 11
            var textBlocks: [NSTextBlock] = []

            // Tables first, whatever order the parser numbered them in: table, then row, then cell.
            for component in ordered {
                if case .table(let columns) = component.kind {
                    let state = tables[component.identity] ?? TableState(columns: columns)
                    tables[component.identity] = state
                    activeTable = state
                }
            }
            for component in ordered {
                switch component.kind {
                case .tableHeaderRow: startRow(identity: component.identity, header: true)
                case .tableRow: startRow(identity: component.identity, header: false)
                default: break
                }
            }
            var listDepth = 0
            var listItem: Component?
            var listKind: PresentationIntent.Kind?

            for component in ordered {
                switch component.kind {
                case .blockQuote:
                    quoteDepth += 1
                    quote = component.identity
                    color = .secondaryLabelColor
                case .orderedList, .unorderedList:
                    listDepth += 1
                    listKind = component.kind
                case .listItem:
                    listItem = component
                case .codeBlock(let hint):
                    isCode = true
                    codeLanguage = hint.flatMap(Language.detect(hint:))
                    codeBlock = component.identity
                    font = Theme.monospaced(style.codeSize)
                    paragraph.lineHeightMultiple = 1.15
                    paragraph.paragraphSpacing = 0
                case .header(let level):
                    let sizes: [CGFloat] = [30, 23, 19, 16.5, 15, 14]
                    font = NSFont.systemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: level <= 2 ? .bold : .semibold)
                    paragraph.paragraphSpacingBefore = level <= 2 ? 14 : 8
                    paragraph.paragraphSpacing = level <= 2 ? 10 : 6
                    paragraph.lineHeightMultiple = 1.1
                    if level >= 6 { color = .secondaryLabelColor }
                    if level <= 2 {
                        rule = true
                        paragraph.paragraphSpacing = 18
                    }
                case .table, .tableHeaderRow, .tableRow:
                    break
                case .tableCell(let column):
                    if let table = activeTable {
                        if blockID != lastBlock {
                            // Cells with no text produce no runs; fill the gaps so columns line up.
                            while table.nextColumn < column {
                                appendEmptyCell(table, column: table.nextColumn)
                            }
                        }
                        let cell = cellBlock(table, column: column)
                        textBlocks.append(cell)
                        paragraph.alignment = column < table.alignments.count ? table.alignments[column] : .natural
                        paragraph.paragraphSpacing = 0
                        paragraph.lineHeightMultiple = 1.1
                        if table.isHeader { font = NSFont.systemFont(ofSize: style.bodySize - 1, weight: .semibold) } else { font = NSFont.systemFont(ofSize: style.bodySize - 1) }
                        table.nextColumn = column + 1
                    }
                case .thematicBreak, .paragraph:
                    break
                @unknown default:
                    break
                }
            }

            // Quotes and code blocks are indented; MarkdownTextView draws the bar or box in the margin.
            let baseIndent = CGFloat(quoteDepth) * 18 + (codeBlock != nil ? 16 : 0)
            paragraph.headIndent = baseIndent
            paragraph.firstLineHeadIndent = baseIndent
            if codeBlock != nil { paragraph.tailIndent = -16 }

            if listDepth > 0 {
                let hang: CGFloat = 20
                let head = baseIndent + CGFloat(listDepth) * 22 + 2
                paragraph.headIndent = head
                paragraph.firstLineHeadIndent = head
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: head)]
                paragraph.paragraphSpacing = 5
                if let item = listItem, blockID != lastBlock, !seenItems.contains(item.identity) {
                    seenItems.insert(item.identity)
                    paragraph.firstLineHeadIndent = head - hang
                    if text.hasPrefix("[ ] ") {
                        prefix = "☐\t"
                        text.removeFirst(4)
                    } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                        prefix = "☑\t"
                        text.removeFirst(4)
                        color = .secondaryLabelColor
                    } else if case .orderedList = listKind, case .listItem(let ordinal) = item.kind {
                        prefix = "\(ordinal).\t"
                    } else {
                        prefix = ["•", "◦", "▪"][min(listDepth - 1, 2)] + "\t"
                    }
                }
                if !isCode { paragraph.lineHeightMultiple = 1.18 }
            }
            paragraph.textBlocks = textBlocks

            // Inline styling
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if let codeBlock = codeBlock { attributes[MarkdownRenderer.codeBlockKey] = codeBlock }
            if let quote = quote { attributes[MarkdownRenderer.quoteKey] = quote }
            if rule { attributes[MarkdownRenderer.ruleKey] = true }
            if !isCode {
                let bold = inline.contains(.stronglyEmphasized)
                let italic = inline.contains(.emphasized)
                if inline.contains(.code) {
                    attributes[.font] = Theme.monospaced(font.pointSize * 0.88)
                    attributes[.backgroundColor] = MarkdownRenderer.codeBackground
                } else if bold || italic {
                    attributes[.font] = MarkdownRenderer.font(font, bold: bold, italic: italic)
                }
                if inline.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                }
                if inline.contains(.inlineHTML) || inline.contains(.blockHTML) {
                    attributes[.font] = Theme.monospaced(font.pointSize * 0.88)
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                }
                if let link = link {
                    attributes[.link] = link
                    attributes[.toolTip] = link.absoluteString
                }
            }

            if let prefix = prefix {
                var prefixAttributes = attributes
                prefixAttributes[.font] = bodyFont
                prefixAttributes[.foregroundColor] = NSColor.secondaryLabelColor
                prefixAttributes.removeValue(forKey: .link)
                prefixAttributes.removeValue(forKey: .backgroundColor)
                write(prefix, prefixAttributes)
            }

            if let imageURL = imageURL, let attachment = MarkdownRenderer.attachment(for: imageURL, baseURL: baseURL, maxWidth: style.imageMaxWidth) {
                var imageAttributes = attributes
                imageAttributes[.attachment] = attachment
                write("\u{FFFC}", imageAttributes)
            } else {
                let start = output.length
                let startsBlock = blockID != lastBlock
                write(text, attributes)
                if isCode, let language = codeLanguage {
                    for token in SyntaxHighlighter.tokens(in: text, language: language) {
                        output.addAttribute(.foregroundColor, value: Theme.color(for: token.kind),
                                            range: NSRange(location: start + token.range.location, length: token.range.length))
                    }
                }
                if isCode { padCodeBlock(start: start, length: output.length - start, startsBlock: startsBlock, base: paragraph) }
            }

            lastBlock = blockID
            lastParagraph = paragraph
            lastAttributes = attributes
            lastAttributes.removeValue(forKey: .link)
            lastAttributes.removeValue(forKey: .attachment)
            lastAttributes.removeValue(forKey: .backgroundColor)
        }

        /// Leaves room above the first line and below the last so the drawn box has padding.
        private func padCodeBlock(start: Int, length: Int, startsBlock: Bool, base: NSParagraphStyle) {
            guard length > 0 else { return }
            let text = output.mutableString
            if startsBlock {
                let first = text.paragraphRange(for: NSRange(location: start, length: 0))
                let style = base.mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacingBefore = 12
                output.addAttribute(.paragraphStyle, value: style, range: first)
            }
            let lastLocation = max(start, start + length - 1)
            let last = text.paragraphRange(for: NSRange(location: lastLocation, length: 0))
            let style = ((output.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle) ?? base).mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = 22
            output.addAttribute(.paragraphStyle, value: style, range: last)
        }

        private mutating func startRow(identity: Int, header: Bool) {
            guard let table = activeTable, table.rowIdentity != identity else { return }
            if table.rowIdentity != nil {
                endParagraph()
                padRow(table)
            }
            table.rowIdentity = identity
            table.row += 1
            table.nextColumn = 0
            table.isHeader = header
        }

        private func cellBlock(_ table: TableState, column: Int) -> NSTextTableBlock {
            let cell = NSTextTableBlock(table: table.table, startingRow: table.row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            cell.setWidth(1, type: .absoluteValueType, for: .border)
            cell.setBorderColor(.separatorColor)
            cell.setWidth(6, type: .absoluteValueType, for: .padding)
            cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
            if table.isHeader { cell.backgroundColor = MarkdownRenderer.headerBackground }
            return cell
        }

        private mutating func appendEmptyCell(_ table: TableState, column: Int) {
            endParagraph()
            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [cellBlock(table, column: column)]
            write(" \n", [.font: bodyFont, .paragraphStyle: paragraph])
            table.nextColumn = column + 1
        }

        private mutating func padRow(_ table: TableState) {
            guard table.rowIdentity != nil else { return }
            while table.nextColumn < table.table.numberOfColumns {
                appendEmptyCell(table, column: table.nextColumn)
            }
        }
    }

    static func font(_ base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    static func attachment(for url: URL, baseURL: URL?, maxWidth: CGFloat) -> NSTextAttachment? {
        let resolved = url.scheme == nil ? URL(fileURLWithPath: url.path, relativeTo: baseURL) : url
        guard resolved.isFileURL, let image = NSImage(contentsOf: resolved), image.size.width > 0 else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        let scale = min(1, maxWidth / image.size.width)
        attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        return attachment
    }
}
