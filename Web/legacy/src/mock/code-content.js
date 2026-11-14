// 演示代码 / 配置文件内容，供文件预览与编辑使用。
export const codeFiles = {
  'Sources/ClaudeDeck/main.swift': `import AppKit
import SwiftUI

@main
struct ClaudePickerApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
`,
  'Sources/ClaudeDeck/Models.swift': `import Foundation

struct Project: Identifiable {
    let id: String
    let name: String
    let path: String
    var sessions: [Session]
}

struct WorkspacePreview {
    var selectedPath: String?
    var mode: PreviewMode = .rendered
}

enum PreviewMode {
    case rendered
    case source
}
`,
  'Sources/ClaudeDeck/GitPanel.swift': `import SwiftUI

struct GitPanel: View {
    @ObservedObject var store: GitStore

    var body: some View {
        HSplitView {
            changesSidebar
                .frame(minWidth: 280)
            DiffView(file: store.selectedFile)
        }
        .background(Color.workspace)
    }
}
`,
  'Sources/ClaudeDeck/GitService.swift': `import Foundation

final class GitService {
    func changedFiles() throws -> [GitFile] {
        let output = try shell.run("git", "status", "--porcelain")
        return GitFileParser.parse(output)
    }
}
`,
  'Sources/ClaudeDeck/LegacySession.swift': `import Foundation

final class LegacySessionStore {
    private var sessions: [String: LegacySession] = [:]

    func append(_ session: LegacySession) {
        sessions[session.id] = session
    }
}
`,
  'package.json': `{
  "name": "claude-picker",
  "version": "0.3.0",
  "private": true,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "test": "node --test"
  }
}
`,
};

codeFiles['data/pipeline.yaml'] = `phases:
  - build
  - test
  - package

artifacts:
  - ClaudePicker.app
  - ClaudePicker.dmg

preview:
  live: true
  formats:
    - markdown
    - mermaid
    - html
`;
