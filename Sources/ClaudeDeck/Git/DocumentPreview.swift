import Foundation

/// 桌面端只读文档与压缩包预览解析器（零第三方依赖，不向磁盘解包）。
/// 使用 macOS 内置 `/usr/bin/unzip`、`/usr/bin/zipinfo`、`/usr/bin/tar` 和 `Foundation.XMLParser`。
enum DocumentPreview {
    /// 深度解析的文件大小上限（32 MB），避免超大包阻塞预览。
    static let maxInspectBytes = 32 * 1024 * 1024
    private static let maxArchiveEntries = 300
    private static let maxSheets = 20
    private static let maxSheetRows = 200
    private static let maxSheetCols = 30
    private static let maxSlides = 80
    private static let maxToolOutputBytes = 8 * 1024 * 1024

    // MARK: - 压缩包清单（不解包）

    static func archiveEntries(file: URL) -> [[String]]? {
        let ext = file.pathExtension.lowercased()
        if ["zip", "jar", "war", "epub"].contains(ext) {
            return zipEntries(file: file)
        }
        if ["tar", "tgz", "gz", "bz2", "xz"].contains(ext) {
            return tarEntries(file: file)
        }
        return nil
    }

    private static func zipEntries(file: URL) -> [[String]]? {
        // `zipinfo -l` 输出固定列：权限 版本 系统 未压缩大小 类型 压缩大小 日期 时间 路径
        guard let output = runTool("/usr/bin/zipinfo", arguments: ["-l", file.path]),
              let text = String(data: output, encoding: .utf8)
        else { return nil }
        var entries: [[String]] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            // 过滤首行 Archive: 和尾行汇总
            if line.hasPrefix("Archive:") || line.hasPrefix("Zip file size:") || line.contains("bytes uncompressed") {
                continue
            }
            guard let parsed = parseZipInfoLine(line) else { continue }
            if parsed.name.hasSuffix("/") { continue }
            entries.append([parsed.name, formatBytes(parsed.size)])
            if entries.count >= maxArchiveEntries { break }
        }
        return entries
    }

    private static func parseZipInfoLine(_ line: String) -> (name: String, size: Int64)? {
        // 格式如: ?rw-------  2.0 unx       11 b-       11 stor 26-Nov-26 16:07 notes/readme.txt
        var idx = line.startIndex
        var tokens: [Substring] = []
        while tokens.count < 9 && idx < line.endIndex {
            while idx < line.endIndex && line[idx] == " " { idx = line.index(after: idx) }
            guard idx < line.endIndex else { break }
            let start = idx
            while idx < line.endIndex && line[idx] != " " { idx = line.index(after: idx) }
            tokens.append(line[start..<idx])
        }
        guard tokens.count == 9, let size = Int64(tokens[3]) else { return nil }
        while idx < line.endIndex && line[idx] == " " { idx = line.index(after: idx) }
        guard idx < line.endIndex else { return nil }
        let name = String(line[idx...])
        return name.isEmpty ? nil : (name, size)
    }

    private static func tarEntries(file: URL) -> [[String]]? {
        guard let output = runTool("/usr/bin/tar", arguments: ["-tvf", file.path]),
              let text = String(data: output, encoding: .utf8)
        else { return nil }
        var entries: [[String]] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("d") { continue }
            // BSD tar: -rw-r--r--  0 user group    1234 Nov 26 10:00 path/to/file
            var idx = line.startIndex
            var tokens: [Substring] = []
            while tokens.count < 8 && idx < line.endIndex {
                while idx < line.endIndex && line[idx] == " " { idx = line.index(after: idx) }
                guard idx < line.endIndex else { break }
                let start = idx
                while idx < line.endIndex && line[idx] != " " { idx = line.index(after: idx) }
                tokens.append(line[start..<idx])
            }
            guard tokens.count == 8, let size = Int64(tokens[4]) else { continue }
            while idx < line.endIndex && line[idx] == " " { idx = line.index(after: idx) }
            guard idx < line.endIndex else { continue }
            let name = String(line[idx...])
            if name.isEmpty || name.hasSuffix("/") { continue }
            entries.append([name, formatBytes(size)])
            if entries.count >= maxArchiveEntries { break }
        }
        return entries.isEmpty ? nil : entries
    }

    static func formatBytes(_ size: Int64) -> String {
        if size < 1024 { return "\(size) B" }
        let kb = Double(size) / 1024.0
        if kb < 1024 { return kb < 10 ? String(format: "%.1f KB", kb) : "\(Int(kb.rounded())) KB" }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1024.0)
    }

    // MARK: - Word (.docx)

    static func docxMarkdown(file: URL) -> String? {
        guard let xmlData = unzipEntry(file: file, entry: "word/document.xml") else { return nil }
        let parser = DocxXMLParser()
        let xml = XMLParser(data: xmlData)
        xml.delegate = parser
        guard xml.parse() else { return nil }
        let text = parser.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Excel (.xlsx)

    static func xlsxSheets(file: URL) -> [SpreadsheetSheet]? {
        guard let wbData = unzipEntry(file: file, entry: "xl/workbook.xml") else { return nil }
        let wbParser = WorkbookXMLParser()
        let wbXML = XMLParser(data: wbData)
        wbXML.delegate = wbParser
        guard wbXML.parse(), !wbParser.sheets.isEmpty else { return nil }

        var relTargets: [String: String] = [:]
        if let relsData = unzipEntry(file: file, entry: "xl/_rels/workbook.xml.rels") {
            let relsParser = RelsXMLParser()
            let relsXML = XMLParser(data: relsData)
            relsXML.delegate = relsParser
            if relsXML.parse() { relTargets = relsParser.targets }
        }

        var sharedStrings: [String] = []
        if let sstData = unzipEntry(file: file, entry: "xl/sharedStrings.xml") {
            let sstParser = SharedStringsXMLParser()
            let sstXML = XMLParser(data: sstData)
            sstXML.delegate = sstParser
            if sstXML.parse() { sharedStrings = sstParser.strings }
        }

        var sheets: [SpreadsheetSheet] = []
        for (index, meta) in wbParser.sheets.prefix(maxSheets).enumerated() {
            let rawTarget = meta.relId.flatMap { relTargets[$0] } ?? "worksheets/sheet\(index + 1).xml"
            let entryPath: String
            if rawTarget.hasPrefix("/") {
                entryPath = String(rawTarget.dropFirst())
            } else if rawTarget.hasPrefix("xl/") {
                entryPath = rawTarget
            } else {
                entryPath = "xl/\(rawTarget)"
            }
            guard let sheetData = unzipEntry(file: file, entry: entryPath) else { continue }
            let sheetParser = WorksheetXMLParser(sharedStrings: sharedStrings,
                                                 maxRows: maxSheetRows,
                                                 maxCols: maxSheetCols)
            let sheetXML = XMLParser(data: sheetData)
            sheetXML.delegate = sheetParser
            if sheetXML.parse() {
                sheets.append(SpreadsheetSheet(name: meta.name, rows: sheetParser.rows))
            }
        }
        return sheets.isEmpty ? nil : sheets
    }

    // MARK: - PowerPoint (.pptx)

    static func pptxSlides(file: URL) -> [PresentationSlide]? {
        guard let listData = runTool("/usr/bin/zipinfo", arguments: ["-1", file.path]),
              let listText = String(data: listData, encoding: .utf8)
        else { return nil }
        let slideEntries = listText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .compactMap { entry -> (Int, String)? in
                guard entry.hasPrefix("ppt/slides/slide"), entry.hasSuffix(".xml") else { return nil }
                let middle = entry.dropFirst("ppt/slides/slide".count).dropLast(".xml".count)
                guard let number = Int(middle) else { return nil }
                return (number, entry)
            }
            .sorted { $0.0 < $1.0 }
            .prefix(maxSlides)

        var slides: [PresentationSlide] = []
        for (number, entry) in slideEntries {
            guard let xmlData = unzipEntry(file: file, entry: entry) else { continue }
            let parser = SlideXMLParser()
            let xml = XMLParser(data: xmlData)
            xml.delegate = parser
            if xml.parse() {
                slides.append(parser.slide(number: number))
            }
        }
        return slides.isEmpty ? nil : slides
    }

    // MARK: - 系统工具调用（直接 exec，不经 shell）

    private static func unzipEntry(file: URL, entry: String) -> Data? {
        runTool("/usr/bin/unzip", arguments: ["-p", file.path, entry])
    }

    private static func runTool(_ executable: String, arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let handle = out.fileHandleForReading
        var buffer = Data()
        while buffer.count < maxToolOutputBytes {
            let chunk = (try? handle.read(upToCount: min(65536, maxToolOutputBytes - buffer.count))) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? buffer : nil
    }
}

// MARK: - OOXML 解析器

private final class DocxXMLParser: NSObject, XMLParserDelegate {
    private var blocks: [String] = []
    private var inTable = false
    private var currentRow: [String] = []
    private var currentCell: [String] = []
    private var inCell = false
    private var inParagraph = false
    private var paragraphText = ""
    private var paragraphHeadingLevel = 0
    private var paragraphIsList = false
    private var captureText = false

    var markdown: String { blocks.joined(separator: "\n\n") }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        switch name {
        case "tbl":
            inTable = true
        case "tr":
            if inTable { currentRow = [] }
        case "tc":
            if inTable { inCell = true; currentCell = [] }
        case "p":
            inParagraph = true
            paragraphText = ""
            paragraphHeadingLevel = 0
            paragraphIsList = false
        case "pStyle":
            if inParagraph, let val = attributeDict["w:val"] ?? attributeDict["val"] {
                let lower = val.lowercased()
                if lower == "title" {
                    paragraphHeadingLevel = 1
                } else if lower == "subtitle" {
                    paragraphHeadingLevel = 2
                } else if lower.hasPrefix("heading"), let n = Int(lower.dropFirst("heading".count)), (1...6).contains(n) {
                    paragraphHeadingLevel = n
                }
            }
        case "numPr":
            if inParagraph { paragraphIsList = true }
        case "t":
            if inParagraph { captureText = true }
        case "tab":
            if inParagraph { paragraphText.append("  ") }
        case "br":
            if inParagraph { paragraphText.append("\n") }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureText { paragraphText.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        switch name {
        case "t":
            captureText = false
        case "p":
            let clean = paragraphText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                if inCell {
                    currentCell.append(clean)
                } else if paragraphHeadingLevel > 0 {
                    blocks.append(String(repeating: "#", count: paragraphHeadingLevel) + " " + clean)
                } else if paragraphIsList {
                    blocks.append("- " + clean)
                } else {
                    blocks.append(clean)
                }
            }
            inParagraph = false
        case "tc":
            if inCell {
                currentRow.append(currentCell.joined(separator: " "))
                inCell = false
            }
        case "tr":
            if inTable, !currentRow.isEmpty {
                blocks.append(currentRow.joined(separator: " | "))
            }
        case "tbl":
            inTable = false
        default:
            break
        }
    }
}

private final class WorkbookXMLParser: NSObject, XMLParserDelegate {
    var sheets: [(name: String, relId: String?)] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard localName(elementName) == "sheet",
              let name = attributeDict["name"], !name.isEmpty else { return }
        let relId = attributeDict["r:id"] ?? attributeDict["id"]
        sheets.append((name: name, relId: relId))
    }
}

private final class RelsXMLParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard localName(elementName) == "Relationship",
              let id = attributeDict["Id"],
              let target = attributeDict["Target"] else { return }
        targets[id] = target
    }
}

private final class SharedStringsXMLParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var inItem = false
    private var inText = false
    private var current = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        if name == "si" {
            inItem = true
            current = ""
        } else if inItem && name == "t" {
            inText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        if name == "t" {
            inText = false
        } else if name == "si" {
            strings.append(current)
            inItem = false
        }
    }
}

private final class WorksheetXMLParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let maxRows: Int
    private let maxCols: Int
    var rows: [[String]] = []

    private var inRow = false
    private var currentRow: [String] = []
    private var inCell = false
    private var cellType = ""
    private var cellColIndex: Int?
    private var inValue = false
    private var inInlineText = false
    private var cellBuffer = ""

    init(sharedStrings: [String], maxRows: Int, maxCols: Int) {
        self.sharedStrings = sharedStrings
        self.maxRows = maxRows
        self.maxCols = maxCols
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard rows.count < maxRows else { return }
        let name = localName(elementName)
        switch name {
        case "row":
            inRow = true
            currentRow = []
        case "c":
            guard inRow else { return }
            inCell = true
            cellType = attributeDict["t"] ?? ""
            cellColIndex = attributeDict["r"].flatMap(columnIndex(from:))
            cellBuffer = ""
        case "v":
            if inCell { inValue = true }
        case "t":
            if inCell && cellType == "inlineStr" { inInlineText = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue || inInlineText { cellBuffer.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        switch name {
        case "v":
            inValue = false
        case "t":
            inInlineText = false
        case "c":
            guard inCell else { return }
            inCell = false
            let resolved: String
            switch cellType {
            case "s":
                if let idx = Int(cellBuffer.trimmingCharacters(in: .whitespacesAndNewlines)),
                   idx >= 0, idx < sharedStrings.count {
                    resolved = sharedStrings[idx]
                } else {
                    resolved = cellBuffer
                }
            case "b":
                resolved = cellBuffer.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? "TRUE" : "FALSE"
            default:
                resolved = cellBuffer
            }
            let targetCol = cellColIndex ?? currentRow.count
            if targetCol < maxCols {
                while currentRow.count <= targetCol { currentRow.append("") }
                currentRow[targetCol] = resolved
            }
        case "row":
            if inRow {
                while currentRow.last?.isEmpty == true { currentRow.removeLast() }
                if !currentRow.isEmpty { rows.append(currentRow) }
                inRow = false
            }
        default:
            break
        }
    }

    private func columnIndex(from reference: String) -> Int? {
        var col = 0
        var seenLetter = false
        for scalar in reference.unicodeScalars {
            if scalar.value >= 65 && scalar.value <= 90 {
                col = col * 26 + Int(scalar.value - 64)
                seenLetter = true
            } else if scalar.value >= 97 && scalar.value <= 122 {
                col = col * 26 + Int(scalar.value - 96)
                seenLetter = true
            } else {
                break
            }
        }
        return seenLetter ? col - 1 : nil
    }
}

private final class SlideXMLParser: NSObject, XMLParserDelegate {
    private var inShape = false
    private var isTitleShape = false
    private var shapeParagraphs: [String] = []
    private var inParagraph = false
    private var paragraphBuffer = ""
    private var captureText = false

    private var titleLines: [String] = []
    private var bodyLines: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        switch name {
        case "sp":
            inShape = true
            isTitleShape = false
            shapeParagraphs = []
        case "ph":
            if inShape, let type = attributeDict["type"]?.lowercased(),
               type == "title" || type == "ctrtitle" {
                isTitleShape = true
            }
        case "p":
            inParagraph = true
            paragraphBuffer = ""
        case "t":
            if inParagraph { captureText = true }
        case "br":
            if inParagraph { paragraphBuffer.append("\n") }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureText { paragraphBuffer.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        switch name {
        case "t":
            captureText = false
        case "p":
            let clean = paragraphBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                if inShape { shapeParagraphs.append(clean) }
                else { bodyLines.append(clean) }
            }
            inParagraph = false
        case "sp":
            if inShape {
                if isTitleShape {
                    titleLines.append(contentsOf: shapeParagraphs)
                } else {
                    bodyLines.append(contentsOf: shapeParagraphs)
                }
                inShape = false
            }
        default:
            break
        }
    }

    func slide(number: Int) -> PresentationSlide {
        if !titleLines.isEmpty {
            return PresentationSlide(title: titleLines.joined(separator: " "),
                                     body: bodyLines.joined(separator: "\n"))
        }
        if let first = bodyLines.first {
            return PresentationSlide(title: first,
                                     body: bodyLines.dropFirst().joined(separator: "\n"))
        }
        return PresentationSlide(title: "第 \(number) 页", body: "（此页无文本内容）")
    }
}

private func localName(_ elementName: String) -> String {
    if let colon = elementName.lastIndex(of: ":") {
        return String(elementName[elementName.index(after: colon)...])
    }
    return elementName
}
