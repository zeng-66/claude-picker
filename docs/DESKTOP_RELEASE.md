# Windows 桌面包与 main 更新

## 实现范围

Windows 桌面运行层位于 `Desktop/`，采用 Electron、React 与 node-pty ConPTY，复用 `Web/` 的当前界面。桌面桥通过 contextBridge 与 IPC 连接真实本地能力，终端由 xterm.js 展示。

当前已实现项目添加、Claude JSONL 会话扫描、新建和恢复 Claude 会话、嵌入式终端、提示词发送、文件读写及修改时间校验、Git 工作台常用操作、设置持久化、MCP 用户配置读取和版本更新。运行 Windows App 前需要安装 Claude Code 和 Git，并确保 PowerShell 可从 PATH 找到 `claude` 和 `git`。

Windows 的 Work 执行器、TAPD、企微、智能体能力包和图形聊天服务仍待移植。相应原生调用返回明确的不可用状态。MCP 的添加、删除及健康检查也尚待适配。完整 Windows 功能对齐与 Windows 实机验收仍未完成。

## 本地构建

```bash
npm ci --prefix Web
npm ci --prefix Desktop
npm --prefix Desktop run dist:win
```

Windows x64 NSIS 安装包输出至 `dist-windows/`。开发分支产物为 `ClaudePickerDev-1.0.0-windows-x64.exe`，正式版由 main 构建，名称为 `ClaudePicker-<版本>-windows-x64.exe`。main、master、test、其他分支分别选择正式、预发布、测试、开发的产品名、应用标识与数据目录。

macOS 开发包按现有入口构建。

```bash
./scripts/build-app.sh --dev --with-chat --zip
```

本轮 Windows 安装包由 macOS 交叉打包生成。Windows ConPTY 原生二进制已随包分发，尚未在本机执行 Windows 程序。仓库提供 Windows CI 中的安装包 ConPTY 冒烟检查，需工作流实际运行后确认结果。Windows 当前包使用本地未提交工作区内容并标记为 dirty，未配置代码签名证书。

## 版本更新

设置新增「版本更新」，提供检查、下载、退出并安装。检查使用 GitHub 的 `commits/main` 获取最新提交，再读取 `main-latest` Release 中的 `manifest.json`。

清单必须声明 main 分支并与当前 main 提交完全匹配。main 更新而安装包尚未生成时显示等待发布。安装包的来源、平台、大小与 SHA-256 均校验通过后才允许安装。下载中的部分文件在失败时清理。新下载和安装互斥。

Windows 启动下载的 NSIS 安装器，随后退出当前应用。存在已打开的终端会话时要求先关闭会话。安装器保留正常的目录选择与安装交互。

macOS 解包并验证 App 标识、提交信息和代码签名，随后由辅助进程等待当前 App 退出，再替换同目录的 `ClaudePicker.app`。更新失败保留或恢复备份。开发版更新至 main 时在同目录安装正式版，使用正式版的数据目录。目录需要当前用户可写。

本次将「拉取 main 最新文件」实现为获取 main 对应的构建产物。运行时无需本机编译工具链。更新源为 `zeng-66/claude-picker`，当前采用公开 GitHub API 与 Release 下载，私有仓库认证暂未实现。

## 发布流水线

`.github/workflows/desktop-main.yml` 在 main 推送或 main 上手动触发时，构建 Windows x64 和 macOS arm64，运行 Windows Git/文件/更新回归及已打包 ConPTY 冒烟检查，汇总安装包与 SHA-256 清单，上传至 `main-latest` Release。

清单最后上传。发布前再次检查构建提交等于远端 main，防止旧构建覆盖新 main 的更新清单。发布流水线中的 macOS 使用现有标准构建入口，图形聊天的外部 `swttch` 资源需要另外准备。

当前工作流尚未推送并运行，远端 main 尚无本轮安装包与清单。实际 App 检查更新时已验证显示「main 最新安装包尚未发布」。正式下载、安装、自更新回滚与跨版本数据兼容仍待发布后做端到端验收。

## 验证记录

- `node Tests/DesktopRegression/main.cjs` 通过，覆盖 Git 状态、暂存提交、空格文件名、差异、文件并发修改拒绝、越界路径、更新来源、提交匹配、下载哈希、失败清理与等待发布。
- `npm --prefix Web run build` 和 `swift build -c release` 通过。
- `scripts/check-session-regressions.sh` 的会话、终端和 Bridge 回归通过，`bash scripts/test-git.sh` 返回 ALL PASS。
- Windows NSIS 开发包已交叉构建生成。
- macOS `--dev --with-chat --zip` 已生成开发包。
- agent-desktop 辅助功能权限被拒绝，使用可用的 CUA 实际重启开发 App，验证设置新增入口、版本与提交展示，以及真实 main 更新检查结果。
- H5 原型已保存在 [desktop-release-prototype](desktop-release-prototype/README.md)，含版本快照、来源摘要、变更记录与批注导出。
