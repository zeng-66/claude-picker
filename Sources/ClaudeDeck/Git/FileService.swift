import Foundation

/// 文件读能力。本项目无沙盒，所有入参路径都必须 realpath 后仍落在项目根内，
/// 否则抛 `PERMISSION_DENIED`。写方法本卡只定签名，由 T9 填实现。
struct FileService: Sendable {
    /// 超过这个大小就建议前端先弹「大文件确认」（SPEC §12 / 计划 T2 的 256 KB 预览阈值）。
    static let previewConfirmThreshold = 256 * 1024
    /// 单次 `read` 默认最多返回 1 MB 文本，超过只给元信息 + `truncated`。
    static let textPreviewLimit = 1024 * 1024
    /// 图片 / PDF 加进 `content` 的 data URL 上限；超过只回元信息，前端提示用系统程序打开。
    static let binaryPreviewLimit = 8 * 1024 * 1024
    /// 音频 / 视频加进 `content` 的 data URL 上限。
    static let mediaPreviewLimit = 16 * 1024 * 1024
    /// `read` 的硬上限，防止前端传个巨大的 `maxBytes` 把进程内存打满。
    static let maxReadBytes = 16 * 1024 * 1024
    /// 默认不展示、不遍历的名字。`CLAUDE_PICKER_IGNORED_NAMES=foo,bar` 可追加。
    static let defaultIgnoredNames: Set<String> = {
        let names: Set<String> = [
            ".git", "node_modules", "dist", "build", ".build", ".next", ".venv", ".DS_Store",
        ]
        let extra = ProcessInfo.processInfo.environment["CLAUDE_PICKER_IGNORED_NAMES"] ?? ""
        let additions = extra
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return names.union(additions)
    }()

    // MARK: - 只读

    /// 列出目录的直接子项（不递归，前端按需展开）。默认过滤 `.git` / `node_modules` / `dist` / `build`。
    func list(projectPath: String, path: String = "", includeIgnored: Bool = false) async throws -> [FileNode] {
        let root = try Self.projectRoot(projectPath)
        let directory = try Self.resolve(path, in: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GitError.commandFailed("目录不存在：\(path.isEmpty ? projectPath : path)", recoverable: true)
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [])
        let rootPath = Self.normalizedPath(root)

        return children.compactMap { child -> FileNode? in
            let name = child.lastPathComponent
            if !includeIgnored, Self.defaultIgnoredNames.contains(name) { return nil }
            // 指向项目外的软链接不展示，避免文件树把用户带到别处。
            let resolved = child.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isInside(resolved, root: rootPath) else { return nil }
            let values = try? child.resourceValues(forKeys: Set(keys))
            let relative = Self.relativePath(child, root: root)
            // 软链接一律按「不可展开的条目」展示，名字里带上原始目标：
            // 既不跟随成环，也不会伪装成普通文件 / 目录。
            if values?.isSymbolicLink == true {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: child.path)) ?? ""
                return FileNode(name: target.isEmpty ? name : "\(name) → \(target)",
                                path: relative,
                                isDirectory: false,
                                size: nil,
                                modifiedAt: values?.contentModificationDate.map { Self.iso($0) },
                                kind: FileKind(path: name))
            }
            let isDirectory = values?.isDirectory ?? false
            return FileNode(name: name,
                            path: relative,
                            isDirectory: isDirectory,
                            size: isDirectory ? nil : values?.fileSize,
                            modifiedAt: values?.contentModificationDate.map { Self.iso($0) },
                            kind: isDirectory ? .other : FileKind(path: name))
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 读文本文件。二进制或超过 `maxBytes` 时 `content` 为 nil，用 `isBinary` / `truncated` / `size` 判断。
    func read(projectPath: String, path: String,
              maxBytes: Int = FileService.textPreviewLimit) async throws -> FileContent {
        let root = try Self.projectRoot(projectPath)
        let file = try Self.resolve(path, in: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            throw GitError.commandFailed("文件不存在：\(path)", recoverable: true)
        }
        guard !isDirectory.boolValue else {
            throw GitError.commandFailed("不能预览目录：\(path)", recoverable: true)
        }
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            throw GitError.permissionDenied("没有权限读取：\(path)")
        }

        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        let modifiedAt = values.contentModificationDate.map { Self.iso($0) } ?? Self.iso(Date())
        let kind = FileKind(path: path)
        let limit = min(max(maxBytes, 1), Self.maxReadBytes)

        // 先看扩展名和文件头，避免把 200 MB 的视频整个读进来。
        var head = Data()
        if let handle = try? FileHandle(forReadingFrom: file) {
            head = (try? handle.read(upToCount: 8192)) ?? Data()
            try? handle.close()
        }
        let mediaByExtension = kind == .audio || kind == .video
        let dataUrlByExtension = kind == .image || kind == .pdf || mediaByExtension
        let structuredBinary = kind == .document || kind == .spreadsheet || kind == .presentation || kind == .archive
        var isBinary = dataUrlByExtension || structuredBinary || head.contains(0)

        var content: String?
        var truncated = false
        var sheets: [SpreadsheetSheet]?
        var slides: [PresentationSlide]?
        var entries: [[String]]?

        if dataUrlByExtension {
            // 图片 / PDF / 音视频走 data URL（复用 `content` 字段）：WKWebView 不能直接读本地
            // file://，前端拿到后塞给 <img> / <object> / <audio> / <video> 即可。
            let byteLimit = mediaByExtension ? Self.mediaPreviewLimit : Self.binaryPreviewLimit
            if size <= byteLimit, let data = try? Data(contentsOf: file) {
                content = "data:\(Self.mimeType(forExtension: file.pathExtension));base64,\(data.base64EncodedString())"
            }
            truncated = true
        } else if structuredBinary {
            truncated = true
            if size <= DocumentPreview.maxInspectBytes {
                switch kind {
                case .document:
                    content = DocumentPreview.docxMarkdown(file: file)
                case .spreadsheet:
                    sheets = DocumentPreview.xlsxSheets(file: file)
                case .presentation:
                    slides = DocumentPreview.pptxSlides(file: file)
                case .archive:
                    entries = DocumentPreview.archiveEntries(file: file)
                default:
                    break
                }
            }
        } else if !isBinary {
            if size > limit {
                truncated = true
            } else if let data = try? Data(contentsOf: file) {
                if let text = String(data: data, encoding: .utf8) {
                    content = text
                } else {
                    // 没有 NUL 但不是合法 UTF-8，同样按二进制处理。
                    isBinary = true
                    truncated = true
                }
            } else {
                truncated = true
            }
        } else {
            truncated = true
        }

        return FileContent(path: Self.relativePath(file, root: root),
                           size: size,
                           modifiedAt: modifiedAt,
                           isBinary: isBinary,
                           content: content,
                           truncated: truncated,
                           kind: kind,
                           sheets: sheets,
                           slides: slides,
                           entries: entries)
    }

    /// 校验目标文件落在项目根内且已存在（非目录），供「打开方式」等原生能力复用边界检查。
    static func resolveExistingFile(projectPath: String, path: String) throws -> URL {
        let root = try projectRoot(projectPath)
        let file = try resolve(path, in: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            throw GitError.commandFailed("文件不存在：\(path)", recoverable: true)
        }
        guard !isDirectory.boolValue else {
            throw GitError.commandFailed("目标路径是目录：\(path)", recoverable: true)
        }
        return file
    }

    func stat(projectPath: String, path: String) async throws -> FileStat {
        let root = try Self.projectRoot(projectPath)
        let url = try Self.resolve(path, in: root)
        let relative = Self.relativePath(url, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FileStat(path: relative, exists: false, isDirectory: false,
                            size: 0, modifiedAt: nil, kind: FileKind(path: path))
        }
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDirectory = values.isDirectory ?? false
        return FileStat(path: relative,
                        exists: true,
                        isDirectory: isDirectory,
                        size: values.fileSize ?? 0,
                        modifiedAt: values.contentModificationDate.map { Self.iso($0) },
                        kind: FileKind(path: path))
    }

    // MARK: - 写操作

    /// 保存前发现文件在外部被改过时，`GitError.detail` 取这个值，前端据此给出「覆盖 / 重新载入」。
    static let staleFileMarker = "STALE_FILE"

    /// 原子保存：先写同目录临时文件，再替换原文件（保留原文件的权限位）。
    /// `expectedModifiedAt` 是读取时拿到的 mtime；与磁盘上的不一致说明外部改过，拒绝覆盖。
    /// 返回保存后的 mtime，调用方用它继续下一次保存。
    @discardableResult
    func write(projectPath: String, path: String, content: String,
               expectedModifiedAt: String? = nil) async throws -> String {
        let root = try Self.projectRoot(projectPath)
        let file = try Self.resolve(path, in: root)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: file.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            throw GitError.commandFailed("不能写入目录：\(path)", recoverable: false)
        }
        guard manager.fileExists(atPath: file.deletingLastPathComponent().path) else {
            throw GitError.commandFailed("目录不存在：\(path)", recoverable: false)
        }
        if let expectedModifiedAt, exists {
            let current = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate.map { Self.iso($0) }
            if let current, current != expectedModifiedAt {
                throw GitError.commandFailed("文件已在外部被修改", detail: Self.staleFileMarker, recoverable: true)
            }
        }

        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).claude-picker-\(UUID().uuidString).tmp")
        do {
            try Data(content.utf8).write(to: temporary, options: [])
            if exists {
                if let permissions = try? manager.attributesOfItem(atPath: file.path)[.posixPermissions] {
                    try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
                }
                _ = try manager.replaceItemAt(file, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: file)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            let reason = (error as NSError).localizedDescription
            if (error as NSError).code == NSFileWriteNoPermissionError {
                throw GitError.permissionDenied("没有权限写入：\(path)")
            }
            throw GitError.commandFailed("保存失败：\(path)", detail: reason, recoverable: true)
        }
        let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        return Self.iso(saved)
    }

    // MARK: - 路径安全

    /// 项目根必须存在且是目录；返回 realpath 后的 URL。支持 `~/project/x` 形式。
    private static func projectRoot(_ projectPath: String) throws -> URL {
        let expanded = (projectPath as NSString).expandingTildeInPath
        let root = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GitError.commandFailed("项目目录不存在：\(projectPath)", recoverable: false)
        }
        return root
    }

    /// 入参路径 realpath 后必须仍在项目根内，否则 `PERMISSION_DENIED`。
    private static func resolve(_ path: String, in root: URL) throws -> URL {
        guard !path.contains("\0") else {
            throw GitError.permissionDenied("路径包含非法字符")
        }
        let candidate = URL(fileURLWithPath: path, relativeTo: root)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isInside(candidate, root: normalizedPath(root)) else {
            throw GitError.permissionDenied("路径越出项目根目录：\(path)")
        }
        return candidate
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func isInside(_ url: URL, root: String) -> Bool {
        let path = normalizedPath(url)
        return path == root || path.hasPrefix(root + "/")
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = normalizedPath(root)
        let path = normalizedPath(url)
        if path == rootPath { return "" }
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// data URL 的 MIME。只覆盖文件预览会遇到的类型，其余按二进制流处理。
    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
}
