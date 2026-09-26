import AppKit
import HandaCore

/// CSV and TSV as a real table: sortable, filterable, editable cell by cell with undo.
final class TableViewer: Viewer, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private let content: TableContent
    private var scrollView: NSScrollView!
    private(set) var tableView: NSTableView!
    /// Indices into `content.rows`, after filtering and sorting.
    private var visibleRows: [Int] = []
    private var numericColumns = Set<Int>()
    private var filter = ""
    private var sortColumn: Int?
    private var sortAscending = true
    private let rowNumberID = NSUserInterfaceItemIdentifier("row-number")

    init(document: Document, content: TableContent) {
        self.content = content
        super.init(document: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var supportsEditing: Bool { document.isWritable }
    override var supportsSearch: Bool { true }
    override var preferredFirstResponder: NSView? { tableView }

    override func loadView() {
        tableView = HandaTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.target = self
        tableView.headerView?.menu = headerMenu()

        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        view = scrollView

        rebuildColumns()
        if content.isLoading {
            content.loadRemaining { [weak self] in
                self?.rebuildColumns()
                self?.document.windowController?.documentStateChanged()
            }
        }
    }

    // MARK: Columns

    private func rebuildColumns() {
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        let sample = content.rows.dropFirst(content.firstDataRow).prefix(300)
        numericColumns = CSV.numericColumns(sample, columnCount: content.columnCount)

        let digits = max(2, String(content.dataRowCount).count)
        let numbers = NSTableColumn(identifier: rowNumberID)
        numbers.title = ""
        numbers.width = CGFloat(digits) * 8 + 18
        numbers.minWidth = 28
        numbers.isEditable = false
        tableView.addTableColumn(numbers)

        let names = content.headerNames
        for index in 0..<content.columnCount {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            column.title = names[index]
            column.headerToolTip = names[index]
            column.width = estimatedWidth(column: index, title: names[index], sample: sample)
            column.minWidth = 40
            column.maxWidth = 2000
            column.sortDescriptorPrototype = NSSortDescriptor(key: "c\(index)", ascending: true)
            if numericColumns.contains(index) { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
        refreshRows()
    }

    private func estimatedWidth(column: Int, title: String, sample: ArraySlice<[String]>) -> CGFloat {
        var longest = title.count + 2
        for row in sample where column < row.count {
            longest = max(longest, min(row[column].count, 60))
        }
        return min(max(CGFloat(longest) * 7.4 + 22, 56), 420)
    }

    private func refreshRows() {
        var rows = Array(content.firstDataRow..<content.rows.count)
        if !filter.isEmpty {
            let needle = filter
            rows = rows.filter { index in
                content.rows[index].contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        if let column = sortColumn {
            let cells = rows.map { content.value(row: $0, column: column) }
            let numbers = numericColumns.contains(column) ? cells.map { NumberParsing.number(from: $0) } : nil
            let ascending = sortAscending
            let order = cells.indices.sorted { a, b in
                let result = TableViewer.compare(cells[a], cells[b], numbers?[a], numbers?[b])
                // Equal cells keep the file's order, whichever way the column is sorted.
                if result == .orderedSame { return a < b }
                return (result == .orderedAscending) == ascending
            }
            rows = order.map { rows[$0] }
        }
        visibleRows = rows
        tableView.reloadData()
        statusChanged()
    }

    /// Numbers in number order and ahead of any text, which goes in Finder's order.
    static func compare(_ left: String, _ right: String, _ leftNumber: Double?, _ rightNumber: Double?) -> ComparisonResult {
        switch (leftNumber, rightNumber) {
        case let (l?, r?): return l < r ? .orderedAscending : l > r ? .orderedDescending : .orderedSame
        case (_?, nil): return .orderedAscending
        case (nil, _?): return .orderedDescending
        case (nil, nil): return left.localizedStandardCompare(right)
        }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn else { return nil }
        let isNumberColumn = tableColumn.identifier == rowNumberID
        let identifier = isNumberColumn ? rowNumberID : NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)
        guard let field = cell.textField, visibleRows.indices.contains(row) else { return cell }
        let dataRow = visibleRows[row]
        if isNumberColumn {
            field.stringValue = "\(dataRow - content.firstDataRow + 1)"
            return cell
        }
        let column = columnIndex(tableColumn)
        field.stringValue = content.value(row: dataRow, column: column)
        field.alignment = numericColumns.contains(column) ? .right : .natural
        field.isEditable = isEditing
        field.font = numericColumns.contains(column) ? TableViewer.numberFont : TableViewer.textFont
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        // Plain frames, not constraints: a table fills the window with hundreds of cells at once,
        // and solving constraints for each one was the slowest part of opening a CSV.
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 100, height: tableView.rowHeight))
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.isSelectable = false
        field.delegate = self
        field.focusRingType = .none
        if identifier == rowNumberID {
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .tertiaryLabelColor
            field.alignment = .right
        } else {
            field.font = TableViewer.textFont
        }
        field.sizeToFit()
        let height = field.frame.height
        field.frame = NSRect(x: 8, y: ((cell.bounds.height - height) / 2).rounded(), width: cell.bounds.width - 16, height: height)
        field.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        cell.addSubview(field)
        cell.textField = field
        return cell
    }

    private static let textFont = NSFont.systemFont(ofSize: 13)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    private func columnIndex(_ column: NSTableColumn) -> Int {
        Int(column.identifier.rawValue.dropFirst()) ?? 0
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else {
            sortColumn = nil
            refreshRows()
            return
        }
        sortColumn = Int(key.dropFirst())
        sortAscending = descriptor.ascending
        refreshRows()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { statusChanged() }

    // MARK: Editing

    override func editingDidChange() {
        tableView.reloadData()
        statusChanged()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard isEditing else { return }
        let row = tableView.clickedRow, column = tableView.clickedColumn
        guard row >= 0, column > 0 else { return }
        tableView.editColumn(column, row: row, with: nil, select: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = tableView.row(for: field), column = tableView.column(for: field)
        guard row >= 0, column > 0, visibleRows.indices.contains(row) else { return }
        let dataRow = visibleRows[row]
        let columnIndex = columnIndex(tableView.tableColumns[column])
        setValue(field.stringValue, row: dataRow, column: columnIndex)
    }

    private func setValue(_ value: String, row: Int, column: Int) {
        let old = content.value(row: row, column: column)
        guard old != value else { return }
        content.setValue(value, row: row, column: column)
        document.undoManager?.registerUndo(withTarget: self) { viewer in
            viewer.setValue(old, row: row, column: column)
        }
        document.undoManager?.setActionName("Edit Cell")
        if let visible = visibleRows.firstIndex(of: row) {
            tableView.reloadData(forRowIndexes: IndexSet(integer: visible), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
    }

    override func finishEditing() {
        if tableView?.currentEditor() != nil { view.window?.makeFirstResponder(tableView) }
    }

    @objc func addRow(_ sender: Any?) {
        guard isEditing else { return }
        let selected = tableView.selectedRowIndexes.last.flatMap { visibleRows[safe: $0] }
        let index = selected.map { $0 + 1 } ?? content.rows.count
        insertRow(Array(repeating: "", count: content.columnCount), at: index)
    }

    private func insertRow(_ values: [String], at index: Int) {
        content.insertRow(values, at: index)
        document.undoManager?.registerUndo(withTarget: self) { viewer in viewer.removeRows([index]) }
        document.undoManager?.setActionName("Add Row")
        refreshRows()
        if let visible = visibleRows.firstIndex(of: index) {
            tableView.selectRowIndexes(IndexSet(integer: visible), byExtendingSelection: false)
            tableView.scrollRowToVisible(visible)
        }
    }

    @objc func deleteRows(_ sender: Any?) {
        guard isEditing else { return }
        let rows = tableView.selectedRowIndexes.compactMap { visibleRows[safe: $0] }
        guard !rows.isEmpty else { NSSound.beep(); return }
        removeRows(rows)
    }

    private func removeRows(_ rows: [Int]) {
        var removed: [(Int, [String])] = []
        for index in rows.sorted(by: >) where content.rows.indices.contains(index) {
            removed.append((index, content.removeRow(at: index)))
        }
        document.undoManager?.registerUndo(withTarget: self) { viewer in
            for (index, values) in removed.reversed() { viewer.content.insertRow(values, at: index) }
            viewer.document.undoManager?.registerUndo(withTarget: viewer) { $0.removeRows(rows) }
            viewer.refreshRows()
        }
        document.undoManager?.setActionName(rows.count == 1 ? "Delete Row" : "Delete Rows")
        tableView.deselectAll(nil)
        refreshRows()
    }

    @objc func addColumn(_ sender: Any?) {
        guard isEditing else { return }
        let clicked = tableView.clickedColumn > 0 ? tableView.clickedColumn : tableView.numberOfColumns - 1
        let index = clicked > 0 ? columnIndex(tableView.tableColumns[clicked]) + 1 : content.columnCount
        insertColumn(at: index, values: nil)
    }

    private func insertColumn(at index: Int, values: [String]?) {
        var values = values
        if values == nil, content.hasHeaderRow {
            values = [TableContent.columnLetter(index)] + Array(repeating: "", count: max(0, content.rows.count - 1))
        }
        content.insertColumn(at: index, values: values)
        document.undoManager?.registerUndo(withTarget: self) { viewer in viewer.removeColumn(at: index) }
        document.undoManager?.setActionName("Add Column")
        rebuildColumns()
    }

    @objc func deleteColumn(_ sender: Any?) {
        guard isEditing else { return }
        let column = tableView.clickedColumn > 0 ? tableView.clickedColumn : tableView.selectedColumn
        guard column > 0 else { NSSound.beep(); return }
        removeColumn(at: columnIndex(tableView.tableColumns[column]))
    }

    private func removeColumn(at index: Int) {
        let removed = content.removeColumn(at: index)
        document.undoManager?.registerUndo(withTarget: self) { viewer in viewer.insertColumn(at: index, values: removed) }
        document.undoManager?.setActionName("Delete Column")
        rebuildColumns()
    }

    @objc func toggleHeaderRow(_ sender: Any?) {
        content.hasHeaderRow.toggle()
        sortColumn = nil
        tableView.sortDescriptors = []
        rebuildColumns()
    }

    @objc func copy(_ sender: Any?) {
        let rows = tableView.selectedRowIndexes.compactMap { visibleRows[safe: $0] }
        guard !rows.isEmpty else { return }
        let text = CSV.clipboardText(rows.map { content.rows[$0] })
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func delete(_ sender: Any?) { deleteRows(sender) }

    private func headerMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "First Row Is Header", action: #selector(toggleHeaderRow(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Insert Column", action: #selector(addColumn(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Delete Column", action: #selector(deleteColumn(_:)), keyEquivalent: "").target = self
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHeaderRow(_:)):
            menuItem.state = content.hasHeaderRow ? .on : .off
            return !content.isLoading
        case #selector(addRow(_:)), #selector(addColumn(_:)):
            return isEditing
        case #selector(deleteRows(_:)), #selector(delete(_:)):
            return isEditing && !tableView.selectedRowIndexes.isEmpty
        case #selector(deleteColumn(_:)):
            return isEditing && (tableView.clickedColumn > 0 || tableView.selectedColumn > 0)
        case #selector(copy(_:)):
            return !tableView.selectedRowIndexes.isEmpty
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    // MARK: Search & status

    override func search(_ query: String) {
        filter = query.trimmingCharacters(in: .whitespaces)
        refreshRows()
    }

    override var statusText: String {
        var parts = ["\(content.format.delimiterName)-separated"]
        if content.isLoading {
            parts.append("Loading all rows…")
        } else {
            parts.append(Formatting.count(content.dataRowCount, "row"))
        }
        parts.append(Formatting.count(content.columnCount, "column"))
        if !filter.isEmpty { parts.append("\(Formatting.count(visibleRows.count, "match", "matches"))") }
        let selected = tableView?.selectedRowIndexes.count ?? 0
        if selected > 1 { parts.append("\(selected) selected") }
        if sortColumn != nil { parts.append("Sorted view (file order unchanged)") }
        parts.append("\(TextDecoding.name(of: content.encoding)) · \(content.format.lineEnding.label)")
        return parts.joined(separator: " · ")
    }

    override func selectedText() -> String? {
        let rows = tableView?.selectedRowIndexes.compactMap { visibleRows[safe: $0] } ?? []
        guard !rows.isEmpty else { return nil }
        return CSV.clipboardText(rows.prefix(200).map { content.rows[$0] })
    }

    override func printOperation(printInfo: NSPrintInfo) -> NSPrintOperation? {
        let info = printInfo.copy() as! NSPrintInfo
        info.orientation = .landscape
        info.horizontalPagination = .fit
        return NSPrintOperation(view: tableView, printInfo: info)
    }
}

/// Delete removes selected rows; Return starts editing the selected cell.
final class HandaTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // delete, forward delete
            if NSApp.sendAction(#selector(TableViewer.deleteRows(_:)), to: nil, from: self) { return }
        }
        super.keyDown(with: event)
    }
}
