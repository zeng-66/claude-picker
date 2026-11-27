import Foundation

// MARK: - 文件类型

/// SPEC §4.2 `GitChange.kind` 与 §4.3 `PreviewFile.kind` 的取值。
enum FileKind: String, Codable, Sendable, CaseIterable {
    case markdown
    case diagram
    case html
    case code
    case csv
    case image
    case pdf
    case document
    case spreadsheet
    case presentation
    case audio
    case video
    case archive
    case other

    private static let byExtension: [String: FileKind] = [
        "md": .markdown, "markdown": .markdown, "mdx": .markdown,
        "mmd": .diagram, "mermaid": .diagram, "dot": .diagram, "puml": .diagram, "drawio": .diagram,
        "html": .html, "htm": .html,
        "csv": .csv, "tsv": .csv,
        "png": .image, "jpg": .image, "jpeg": .image, "gif": .image, "webp": .image,
        "svg": .image, "ico": .image, "bmp": .image, "tiff": .image, "heic": .image,
        "pdf": .pdf,
        "docx": .document,
        "xlsx": .spreadsheet,
        "pptx": .presentation,
        "wav": .audio, "mp3": .audio, "m4a": .audio, "aac": .audio, "ogg": .audio, "flac": .audio,
        "mp4": .video, "mov": .video, "webm": .video, "m4v": .video,
        "zip": .archive, "jar": .archive, "war": .archive, "epub": .archive,
        "tar": .archive, "tgz": .archive, "gz": .archive, "bz2": .archive, "xz": .archive,
    ]

    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "py", "rb", "go", "rs", "java", "kt", "kts", "scala", "php", "cs", "fs", "sh", "bash", "zsh",
        "json", "jsonc", "yaml", "yml", "toml", "ini", "conf", "xml", "plist", "sql", "css", "scss",
        "less", "vue", "svelte", "lua", "pl", "r", "dart", "ex", "exs", "erl", "hs", "clj", "gradle",
    ]

    init(extension ext: String) {
        let key = ext.lowercased()
        if let kind = Self.byExtension[key] {
            self = kind
        } else {
            self = Self.codeExtensions.contains(key) ? .code : .other
        }
    }

    init(path: String) {
        self.init(extension: (path as NSString).pathExtension)
    }
}

// MARK: - Git 只读 DTO

/// SPEC §4.2 的 `GitChange`，补了三态与 porcelain 原始字母。
/// `id` 供 SwiftUI / JS 列表复用，取路径即可（重命名时用新路径）。
struct GitFile: Codable, Sendable, Equatable, Identifiable {
    enum State: String, Codable, Sendable {
        case modified
        case added
        case deleted
        case untracked
    }

    /// 相对项目根的路径。
    let path: String
    /// 重命名/复制时的原路径。
    let oldPath: String?
    let kind: FileKind
    let state: State
    /// 界面上展示的状态字母：`M` / `A` / `D` / `?`。
    let label: String
    /// 索引区有变更（暂存）。
    let staged: Bool
    /// 工作区有变更（未暂存）。
    let unstaged: Bool
    let untracked: Bool
    /// porcelain 原始两位状态码，排查时对照 `git status --short` 用。
    let indexStatus: String
    let workTreeStatus: String
    /// 是否二进制；nil = 尚未判定（`status` 不做额外 diff，`diff` 会给出）。
    let binary: Bool?

    var id: String { path }
}

struct GitStatusSnapshot: Codable, Sendable, Equatable {
    let projectPath: String
    /// nil 表示 detached HEAD。
    let branch: String?
    let detachedHead: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
    let files: [GitFile]

    var clean: Bool { files.isEmpty }
    var changes: Int { files.count }
}

struct GitCommit: Codable, Sendable, Equatable, Identifiable {
    let hash: String
    let shortHash: String
    let message: String
    let author: String
    let authorEmail: String
    /// ISO8601（`git log --format=%aI` 原文）。
    let date: String
    let parents: [String]

    var id: String { hash }
}

struct GitCommitFile: Codable, Sendable, Equatable {
    let path: String
    let additions: Int
    let deletions: Int
    let binary: Bool
}

struct GitCommitDetail: Codable, Sendable, Equatable {
    let commit: GitCommit
    let files: [GitCommitFile]
    let additions: Int
    let deletions: Int
    /// 统一 diff 原文（`git show --patch`）。
    let patch: String
}

struct DiffResult: Codable, Sendable, Equatable {
    let path: String
    let staged: Bool
    let binary: Bool
    let additions: Int
    let deletions: Int
    let patch: String
}

struct GitBranchInfo: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let isCurrent: Bool
    let isRemote: Bool
    let upstream: String?
    let ahead: Int
    let behind: Int
    /// 上游分支被删除时为 true（`%(upstream:track)` == `[gone]`）。
    let upstreamGone: Bool
    let lastCommit: String

    var id: String { name }
}

struct GitTag: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let hash: String
    let date: String
    let subject: String

    var id: String { name }
}

struct GitRemote: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let fetchURL: String
    /// `git remote -v` 没配独立 push URL 时等于 fetchURL。
    let pushURL: String

    var id: String { name }
}

struct GitWorktreeInfo: Codable, Sendable, Equatable, Identifiable {
    let path: String
    let head: String?
    /// 分支短名（`refs/heads/` 去掉）；detached 时为 nil。
    let branch: String?
    let isBare: Bool
    let isLocked: Bool
    let isPrunable: Bool

    var id: String { path }
}

struct GitStash: Codable, Sendable, Equatable, Identifiable {
    /// `stash@{0}` 的下标。
    let index: Int
    let ref: String
    let hash: String
    let message: String
    let date: String

    var id: String { ref }
}

struct GitMergeState: Codable, Sendable, Equatable {
    let merging: Bool
    /// 正在合并进来的引用（分支名，认不出来时是短哈希）。
    let head: String?
    /// 还没解决的冲突文件，相对项目根。
    let conflicts: [String]
}

struct GitReflogEntry: Codable, Sendable, Equatable {
    let hash: String
    /// `HEAD@{3}`
    let selector: String
    let message: String
    let date: String
}

// MARK: - 写操作入参

struct CommitOptions: Codable, Sendable, Equatable {
    var amend: Bool = false
    var signOff: Bool = false
    var noVerify: Bool = false
    var allowEmpty: Bool = false
}

struct CommitResult: Codable, Sendable, Equatable {
    let hash: String
    let shortHash: String
    let message: String
    /// amend 时为 true，前端用来区分「新提交 / 改写」。
    let amended: Bool
}

/// 路径须是项目 .worktrees 的直接子目录。省略时按分支名生成目录。
struct CreateWorktreeInput: Codable, Sendable, Equatable {
    let projectPath: String
    let branch: String
    var path: String? = nil
    /// 省略时取当前分支。
    var baseBranch: String? = nil
}

struct RemoveWorktreeInput: Codable, Sendable, Equatable {
    let projectPath: String
    let path: String
    var force: Bool = false
}

struct WorktreeResult: Codable, Sendable, Equatable {
    let path: String
    let branch: String
}

// MARK: - 文件 DTO

/// 目录树节点（只列直接子项，前端按需展开，避免一次遍历整棵树）。
struct FileNode: Codable, Sendable, Equatable, Identifiable {
    let name: String
    /// 相对项目根的路径，文件树节点 id 也用它。
    let path: String
    let isDirectory: Bool
    /// 目录为 nil。
    let size: Int?
    let modifiedAt: String?
    let kind: FileKind

    var id: String { path }
}

struct SpreadsheetSheet: Codable, Sendable, Equatable {
    let name: String
    let rows: [[String]]
}

struct PresentationSlide: Codable, Sendable, Equatable {
    let title: String
    let body: String
}

struct FileContent: Codable, Sendable, Equatable {
    let path: String
    let size: Int
    let modifiedAt: String
    let isBinary: Bool
    /// 文本且未超过调用方给的 `maxBytes` 时才有值；图片 / PDF / 音视频为 data URL；Word 文档为提取后的 Markdown 正文。
    let content: String?
    /// 内容被截断（二进制或超过 maxBytes）时为 true。
    let truncated: Bool
    let kind: FileKind
    /// Excel 工作表预览数据。
    let sheets: [SpreadsheetSheet]?
    /// PowerPoint 幻灯片预览数据。
    let slides: [PresentationSlide]?
    /// 压缩包只读文件清单（`[文件名, 格式化大小]`）。
    let entries: [[String]]?

    init(path: String, size: Int, modifiedAt: String, isBinary: Bool,
         content: String?, truncated: Bool, kind: FileKind,
         sheets: [SpreadsheetSheet]? = nil,
         slides: [PresentationSlide]? = nil,
         entries: [[String]]? = nil) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
        self.isBinary = isBinary
        self.content = content
        self.truncated = truncated
        self.kind = kind
        self.sheets = sheets
        self.slides = slides
        self.entries = entries
    }
}

struct FileStat: Codable, Sendable, Equatable {
    let path: String
    let exists: Bool
    let isDirectory: Bool
    let size: Int
    let modifiedAt: String?
    let kind: FileKind
}
